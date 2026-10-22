/* Dena.emu link cable for the mGBA libretro core (MPL-2.0, like mGBA).
 * Spec: docs/specs/link-cable.md
 *
 * Copied into mGBA's src/platform/libretro/ by cores/mgba/build.sh, which also
 * adds the two calls into libretro.c. The frontend finds the exported
 * dena_link_attach() with dlsym and hands over a transport (Dena's host owns
 * the socket); without it the core behaves exactly as upstream.
 *
 * Model: two consoles. The side that drives the clock (GB internal clock, GBA
 * normal-mode internal clock, GBA multiplayer parent) sends its word and waits
 * briefly for the other side's word; the other side polls every 512 cycles,
 * answers with its own word and finishes its transfer. */
#include <mgba/core/core.h>
#include <mgba/core/timing.h>
#include <mgba/internal/gb/gb.h>
#include <mgba/internal/gb/io.h>
#include <mgba/internal/gb/sio.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/io.h>
#include <mgba/internal/gba/sio.h>

#include "dena_link_api.h"

#define DENA_LINK_POLL_CYCLES 512
#define DENA_LINK_WAIT_MS 40

static const struct dena_link_api* denaLinkApi;
static struct mCore* denaLinkCore;
static struct mTimingEvent denaLinkPoll;

/* Retro export: the frontend attaches (or detaches with NULL) its transport. */
__attribute__((visibility("default"))) void dena_link_attach(const struct dena_link_api* api) {
	denaLinkApi = api;
}

static bool _linked(void) {
	return denaLinkApi && denaLinkApi->connected(denaLinkApi->user);
}

/* Sends a word and waits for the reply kind. A crossing request from the other
 * side (both consoles drive the clock) is answered with "nothing" so neither
 * side stalls. */
static uint32_t _exchange(uint8_t kind, uint32_t out, uint32_t idle) {
	if (denaLinkApi->send(denaLinkApi->user, kind, out) < 0) {
		return idle;
	}
	uint8_t k;
	uint32_t v;
	while (denaLinkApi->recv(denaLinkApi->user, &k, &v, DENA_LINK_WAIT_MS) > 0) {
		if (k == (uint8_t) (kind | DENA_LINK_REPLY)) {
			return v;
		}
		if (!(k & DENA_LINK_REPLY)) {
			denaLinkApi->send(denaLinkApi->user, k | DENA_LINK_REPLY, idle);
		}
	}
	return idle;
}

/* --- Game Boy / Game Boy Color --- */

static struct GBSIODriver denaGBDriver;

static void _gbWriteSB(struct GBSIODriver* driver, uint8_t value) {
	UNUSED(driver);
	UNUSED(value);
}

static uint8_t _gbWriteSC(struct GBSIODriver* driver, uint8_t sc) {
	struct GBSIO* sio = driver->p;
	if (_linked() && GBRegisterSCIsEnable(sc) && GBRegisterSCIsShiftClock(sc)) {
		/* mGBA's own SIO event shifts pendingSB in over the next 8 bits. */
		sio->pendingSB = _exchange(DENA_LINK_GB, sio->p->memory.io[GB_REG_SB], 0xFF);
	}
	return sc;
}

static void _gbPoll(struct GB* gb, uint8_t kind, uint32_t value) {
	if (kind != DENA_LINK_GB) {
		denaLinkApi->send(denaLinkApi->user, kind | DENA_LINK_REPLY, 0xFFFFFFFF);
		return;
	}
	uint8_t sc = gb->memory.io[GB_REG_SC];
	if (!GBRegisterSCIsEnable(sc) || GBRegisterSCIsShiftClock(sc)) {
		denaLinkApi->send(denaLinkApi->user, DENA_LINK_GB | DENA_LINK_REPLY, 0xFF);
		return;
	}
	denaLinkApi->send(denaLinkApi->user, DENA_LINK_GB | DENA_LINK_REPLY, gb->memory.io[GB_REG_SB]);
	gb->memory.io[GB_REG_SB] = value;
	gb->memory.io[GB_REG_SC] = GBRegisterSCClearEnable(sc);
	gb->memory.io[GB_REG_IF] |= (1 << GB_IRQ_SIO);
	GBUpdateIRQs(gb);
}

/* --- Game Boy Advance --- */

static struct GBASIODriver denaGBADriver;
static struct mTimingEvent denaGBAFinish;
static uint32_t denaGBAOut;
static uint32_t denaGBAIn;

static bool _gbaParent(void) {
	return denaLinkApi->role(denaLinkApi->user) == DENA_LINK_PARENT;
}

static void _gbaSetData(struct GBA* gba, enum GBASIOMode mode, uint32_t value) {
	if (mode == SIO_NORMAL_32) {
		gba->memory.io[REG_SIODATA32_LO >> 1] = value;
		gba->memory.io[REG_SIODATA32_HI >> 1] = value >> 16;
	} else {
		gba->memory.io[REG_SIODATA8 >> 1] = value & 0xFF;
	}
}

static uint32_t _gbaGetData(struct GBA* gba, enum GBASIOMode mode) {
	if (mode == SIO_NORMAL_32) {
		return gba->memory.io[REG_SIODATA32_LO >> 1] | ((uint32_t) gba->memory.io[REG_SIODATA32_HI >> 1] << 16);
	}
	return gba->memory.io[REG_SIODATA8 >> 1] & 0xFF;
}

static void _gbaFinishMulti(struct GBA* gba, uint16_t parent, uint16_t child, int id) {
	struct GBASIO* sio = &gba->sio;
	gba->memory.io[REG_SIOMULTI0 >> 1] = parent;
	gba->memory.io[REG_SIOMULTI1 >> 1] = child;
	gba->memory.io[REG_SIOMULTI2 >> 1] = 0xFFFF;
	gba->memory.io[REG_SIOMULTI3 >> 1] = 0xFFFF;
	sio->rcnt |= 1;
	sio->siocnt = GBASIOMultiplayerClearBusy(sio->siocnt);
	sio->siocnt = GBASIOMultiplayerSetId(sio->siocnt, id);
	if (GBASIOMultiplayerIsIrq(sio->siocnt)) {
		GBARaiseIRQ(gba, GBA_IRQ_SIO, 0);
	}
}

static void _gbaFinishNormal(struct GBA* gba, uint32_t value) {
	struct GBASIO* sio = &gba->sio;
	_gbaSetData(gba, sio->mode, value);
	sio->siocnt = GBASIONormalClearStart(sio->siocnt);
	if (GBASIONormalIsIrq(sio->siocnt)) {
		GBARaiseIRQ(gba, GBA_IRQ_SIO, 0);
	}
}

static void _gbaFinish(struct mTiming* timing, void* context, uint32_t cyclesLate) {
	UNUSED(timing);
	UNUSED(cyclesLate);
	struct GBA* gba = context;
	if (gba->sio.mode == SIO_MULTI) {
		_gbaFinishMulti(gba, denaGBAOut, denaGBAIn, 0);
	} else {
		_gbaFinishNormal(gba, denaGBAIn);
	}
}

static uint16_t _gbaWriteRegister(struct GBASIODriver* driver, uint32_t address, uint16_t value) {
	struct GBASIO* sio = driver->p;
	struct GBA* gba = sio->p;
	if (address != REG_SIOCNT) {
		return value;
	}
	bool linked = _linked();
	switch (sio->mode) {
	case SIO_MULTI:
		value &= 0xFF83;
		if (linked) {
			value |= 0x0008; /* all terminals ready */
			value = GBASIOMultiplayerSetSlave(value, !_gbaParent());
		} else {
			value |= 0x000C;
		}
		if (!linked || !_gbaParent()) {
			/* Children cannot start a transfer; keep a busy flag we set. */
			value = (value & ~0x0080) | (sio->siocnt & 0x0080);
			break;
		}
		if ((value & 0x0080) && !(sio->siocnt & 0x0080)) {
			denaGBAOut = gba->memory.io[REG_SIOMLT_SEND >> 1];
			denaGBAIn = _exchange(DENA_LINK_GBA_MULTI, denaGBAOut, 0xFFFF) & 0xFFFF;
			mTimingDeschedule(&gba->timing, &denaGBAFinish);
			mTimingSchedule(&gba->timing, &denaGBAFinish,
			                GBASIOCyclesPerTransfer[GBASIOMultiplayerGetBaud(value)][1]);
		}
		break;
	case SIO_NORMAL_8:
	case SIO_NORMAL_32:
		value |= 0x0004;
		if ((value & 0x0080) && GBASIONormalIsSc(value) && !(sio->siocnt & 0x0080)) {
			uint32_t idle = sio->mode == SIO_NORMAL_32 ? 0xFFFFFFFF : 0xFF;
			uint32_t out = _gbaGetData(gba, sio->mode);
			denaGBAIn = linked ? _exchange(DENA_LINK_GBA_NORMAL, out, idle) : idle;
			mTimingDeschedule(&gba->timing, &denaGBAFinish);
			mTimingSchedule(&gba->timing, &denaGBAFinish, sio->mode == SIO_NORMAL_32 ? 32 * 8 : 8 * 8);
		}
		break;
	default:
		break;
	}
	return value;
}

static void _gbaPoll(struct GBA* gba, uint8_t kind, uint32_t value) {
	struct GBASIO* sio = &gba->sio;
	if (kind == DENA_LINK_GBA_MULTI && sio->mode == SIO_MULTI && !_gbaParent()) {
		uint16_t own = gba->memory.io[REG_SIOMLT_SEND >> 1];
		denaLinkApi->send(denaLinkApi->user, kind | DENA_LINK_REPLY, own);
		_gbaFinishMulti(gba, value, own, 1);
		return;
	}
	if (kind == DENA_LINK_GBA_NORMAL && (sio->mode == SIO_NORMAL_8 || sio->mode == SIO_NORMAL_32) &&
	    (sio->siocnt & 0x0080) && !GBASIONormalIsSc(sio->siocnt)) {
		denaLinkApi->send(denaLinkApi->user, kind | DENA_LINK_REPLY, _gbaGetData(gba, sio->mode));
		_gbaFinishNormal(gba, value);
		return;
	}
	denaLinkApi->send(denaLinkApi->user, kind | DENA_LINK_REPLY,
	                  kind == DENA_LINK_GBA_MULTI ? 0xFFFF : 0xFFFFFFFF);
}

/* --- Shared --- */

static struct mTiming* _timing(void) {
	if (denaLinkCore->platform(denaLinkCore) == mPLATFORM_GBA) {
		return &((struct GBA*) denaLinkCore->board)->timing;
	}
	return &((struct GB*) denaLinkCore->board)->timing;
}

static void _poll(struct mTiming* timing, void* context, uint32_t cyclesLate) {
	UNUSED(context);
	UNUSED(cyclesLate);
	if (_linked()) {
		uint8_t kind;
		uint32_t value;
		while (denaLinkApi->recv(denaLinkApi->user, &kind, &value, 0) > 0) {
			if (kind & DENA_LINK_REPLY) {
				continue; /* a late reply to a transfer that already timed out */
			}
			if (denaLinkCore->platform(denaLinkCore) == mPLATFORM_GBA) {
				_gbaPoll(denaLinkCore->board, kind, value);
			} else {
				_gbPoll(denaLinkCore->board, kind, value);
			}
		}
	}
	mTimingSchedule(timing, &denaLinkPoll, DENA_LINK_POLL_CYCLES);
}

/* Called by libretro.c once the ROM is loaded. */
static void denaLinkInstall(struct mCore* core) {
	denaLinkCore = core;
	denaLinkPoll.context = NULL;
	denaLinkPoll.name = "Dena link poll";
	denaLinkPoll.callback = _poll;
	denaLinkPoll.priority = 0x31;
	if (core->platform(core) == mPLATFORM_GBA) {
		struct GBA* gba = core->board;
		memset(&denaGBADriver, 0, sizeof(denaGBADriver));
		denaGBADriver.writeRegister = _gbaWriteRegister;
		denaGBAFinish.context = gba;
		denaGBAFinish.name = "Dena link finish";
		denaGBAFinish.callback = _gbaFinish;
		denaGBAFinish.priority = 0x80;
		GBASIOSetDriver(&gba->sio, &denaGBADriver, SIO_NORMAL_8);
		GBASIOSetDriver(&gba->sio, &denaGBADriver, SIO_MULTI);
	} else if (core->platform(core) == mPLATFORM_GB) {
		struct GB* gb = core->board;
		memset(&denaGBDriver, 0, sizeof(denaGBDriver));
		denaGBDriver.writeSB = _gbWriteSB;
		denaGBDriver.writeSC = _gbWriteSC;
		GBSIOSetDriver(&gb->sio, &denaGBDriver);
	} else {
		denaLinkCore = NULL;
	}
}

/* Called by libretro.c at the start of every retro_run: resets and state
 * loads clear the timing queue, so the poll is re-armed here. */
static void denaLinkFrame(void) {
	if (!denaLinkCore || !denaLinkApi) {
		return;
	}
	struct mTiming* timing = _timing();
	if (!mTimingIsScheduled(timing, &denaLinkPoll)) {
		mTimingSchedule(timing, &denaLinkPoll, DENA_LINK_POLL_CYCLES);
	}
}

static void denaLinkRemove(void) {
	denaLinkCore = NULL;
}
