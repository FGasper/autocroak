#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static Perl_ppaddr_t opcodes[OP_max];
#define pragma_name "autocroak"

#ifndef cop_hints_exists_pvs
#define cop_hints_exists_pvs(cop, key, flags) cop_hints_fetch_pvs(cop, key, flags | 0x00000002)
#endif

#define autocroak_enabled() cop_hints_exists_pvs(PL_curcop, pragma_name, 0)

#define INC_WRAPPER(TYPE)\
static OP* croak_##TYPE(pTHX) {\
	OP* next = opcodes[OP_##TYPE](aTHX);\
	if (autocroak_enabled()) {\
		dSP;\
		if (!SvOK(TOPs))\
			Perl_croak(aTHX_ "Could not call %s: %s", PL_op_name[OP_##TYPE], strerror(errno));\
	}\
	return next;\
}
#include "autocroak.inc"
#undef INC_WRAPPER

static OP* croak_SYSTEM(pTHX) {
	OP* next = opcodes[OP_SYSTEM](aTHX);
	if (autocroak_enabled()) {
		dSP;
		if (SvTRUE(TOPs))
			Perl_croak(aTHX_ "Can't call system: it returned %d", SvUV(TOPs));
	}
	return next;
}

static OP* croak_PRINT(pTHX) {
	OP* next = opcodes[OP_PRINT](aTHX);
	if (autocroak_enabled()) {
		dSP;
		if (!SvTRUE(TOPs))
			Perl_croak(aTHX_ "Could not print: %s", strerror(errno));
	}
	return next;
}

static OP* croak_FLOCK(pTHX) {
	if (autocroak_enabled()) {
		dSP;
		int non_blocking = TOPu & LOCK_NB;
		OP* next = opcodes[OP_FLOCK](aTHX);
		SPAGAIN;
		if (!SvOK(TOPs) && (!non_blocking || errno != EAGAIN))
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
#define INC_WRAPPER(TYPE) \
		opcodes[OP_##TYPE] = PL_ppaddr[OP_##TYPE];\
		PL_ppaddr[OP_##TYPE] = croak_##TYPE;
#include "autocroak.inc"
		INC_WRAPPER(SYSTEM)
		INC_WRAPPER(PRINT)
		INC_WRAPPER(FLOCK)
#undef INC_WRAPPER
	}
	OP_CHECK_MUTEX_UNLOCK;
