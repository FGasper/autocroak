#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static Perl_ppaddr_t opcodes[OP_max];
#define pragma_base "autocroak/"
#define pragma_name pragma_base "enabled"
#define pragma_name_length (sizeof(pragma_name) - 1)
static U32 pragma_hash;

#ifndef cop_hints_exists_pvn
#define cop_hints_exists_pvn(cop, key, len, hash, flags) cop_hints_fetch_pvn(cop, key, len, hash, flags | 0x02)
#endif

#define autocroak_enabled() cop_hints_exists_pvn(PL_curcop, pragma_name, pragma_name_length, pragma_hash, 0)

bool S_errno_in_bitset(pTHX_ SV* arg, bool default_result) {
	if (SvPOK(arg)) {
		size_t byte = errno / 8;
		size_t position = 1 << (errno % 8);
		return byte < SvCUR(arg) && SvPVX(arg)[byte] & position;
	}
	return default_result;
}

#define allowed_for(TYPE, default_result) S_errno_in_bitset(aTHX_ cop_hints_fetch_pvs(PL_curcop, pragma_base #TYPE, 0), default_result)

#define INC_WRAPPER(TYPE, CHECK)\
static OP* croak_##TYPE(pTHX) {\
	OP* next = opcodes[OP_##TYPE](aTHX);\
	if (autocroak_enabled()) {\
		dSP;\
		if (!CHECK(TOPs) && !allowed_for(TYPE, FALSE))\
			Perl_croak(aTHX_ "Could not call %s: %s", PL_op_name[OP_##TYPE], strerror(errno));\
	}\
	return next;\
}

#define INC_WRAPPER_FT(TYPE, NAME) \
static OP* croak_##TYPE(pTHX) {\
	dSP;\
	SV* filename = TOPs;\
	OP* next = opcodes[OP_##TYPE](aTHX);\
	if (autocroak_enabled()) {\
		SPAGAIN;\
		if (!SvOK(TOPs) && !allowed_for(TYPE, TRUE)) {\
				SV* message = newSVpvs("Could not " NAME " '");\
				sv_catsv(message, filename);\
				sv_catpvf(message, "': %s", strerror(errno));\
				croak_sv(message);\
		}\
	}\
	return next;\
}

#include "autocroak.inc"
#undef INC_WRAPPER_FT
#undef INC_WRAPPER

static OP* croak_OPEN(pTHX) {
	if (autocroak_enabled()) {
		dSP;
		SV **mark = PL_stack_base + TOPMARK;
		if (SP - MARK == 3 && SvPOK(MARK[3])) {
			SV* mode = sv_2mortal(SvREFCNT_inc(MARK[2]));
			SV* filename = sv_2mortal(SvREFCNT_inc(MARK[3]));
			OP* next = opcodes[OP_OPEN](aTHX);
			SPAGAIN;
			if (!SvOK(TOPs) && !allowed_for(OPEN, FALSE)) {
				SV* message = newSVpvs("Could not open file '");
				sv_catsv(message, filename); // this will handle unicode
				sv_catpvf(message, "' with mode %s: %s", SvPV_nolen(mode), strerror(errno));
				croak_sv(message);
			}
			return next;
		}
		else {
			OP* next = opcodes[OP_OPEN](aTHX);
			SPAGAIN;
			if (!SvOK(TOPs) && !allowed_for(OPEN, FALSE))
				Perl_croak(aTHX_ "Could not open: %s", strerror(errno));
			return next;
		}
	}
	else
		return opcodes[OP_OPEN](aTHX);
}

static OP* croak_SYSTEM(pTHX) {
	OP* next = opcodes[OP_SYSTEM](aTHX);
	if (autocroak_enabled()) {
		dSP;
		if (SvTRUE(TOPs) && !allowed_for(SYSTEM, FALSE))
			Perl_croak(aTHX_ "Can't call system: it returned %d", SvUV(TOPs));
	}
	return next;
}

static OP* croak_FLOCK(pTHX) {
	if (autocroak_enabled()) {
		dSP;
		int non_blocking = TOPu & LOCK_NB;
		OP* next = opcodes[OP_FLOCK](aTHX);
		SPAGAIN;
		if (!SvOK(TOPs) && !allowed_for(FLOCK, non_blocking && errno == EAGAIN))
			Perl_croak(aTHX_ "Could not flock: %s", strerror(errno));
		return next;
	}
	else
		return opcodes[OP_FLOCK](aTHX);
}

static unsigned initialized;

MODULE = autocroak				PACKAGE = autocroak

PROTOTYPES: DISABLED

BOOT:
	OP_CHECK_MUTEX_LOCK;
	if (!initialized) {
		initialized = 1;
		PERL_HASH(pragma_hash, pragma_name, pragma_name_length);
#define INC_WRAPPER(TYPE, CHECK) \
		opcodes[OP_##TYPE] = PL_ppaddr[OP_##TYPE];\
		PL_ppaddr[OP_##TYPE] = croak_##TYPE;
#define INC_WRAPPER_FT(TYPE, NAME) INC_WRAPPER(TYPE, NAME)
#include "autocroak.inc"
		INC_WRAPPER(OPEN, 0)
		INC_WRAPPER(SYSTEM, 0)
		INC_WRAPPER(FLOCK, 0)
#undef INC_WRAPPER_FT
#undef INC_WRAPPER
	}
	OP_CHECK_MUTEX_UNLOCK;
