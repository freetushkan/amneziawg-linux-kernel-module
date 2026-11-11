/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Per-peer protocol fallback for older AmneziaWG versions and WireGuard.
 *
 * The device configuration describes the newest wire format this host
 * speaks. A peer running an older AmneziaWG (or vanilla WireGuard) may lack
 * some of its features. For every peer we keep a small mask of features the
 * peer was seen to lack and shape outgoing packets accordingly. A zero mask
 * means "use the device configuration as is", which is exactly the upstream
 * behaviour, so peers speaking the full protocol are not affected at all.
 *
 * The mask is only learned from authenticated packets (a handshake message
 * that was consumed successfully or a transport packet that decrypted and
 * passed the replay check), so an attacker cannot downgrade a peer.
 */

#ifndef _AWG_FALLBACK_H
#define _AWG_FALLBACK_H

#include "queueing.h"
#include "messages.h"
#include "type.h"

#include <linux/types.h>
#include <linux/compiler.h>

struct chacha_state;

enum awg_lack {
	AWG_LACK_AWG	= 1U << 0, /* vanilla WireGuard: no H1-H4, no S1-S4 */
	AWG_LACK_RANGE	= 1U << 1, /* AWG 1.x: H1-H4 fixed to the range low bound */
	AWG_LACK_S34	= 1U << 2, /* no S3/S4 on cookie and transport packets */
	AWG_LACK_HP	= 1U << 3, /* no header protection */
	AWG_LACK_V3	= 1U << 4, /* no random trailers / content padding */
	AWG_LACK_ALL	= 0x1f
};

enum awg_peer_state {
	AWG_STATE_S34_SEEN = 1U << 5, /* AWG_LACK_S34 observed, not guessed */
	AWG_STATE_LEARNED  = 1U << 6  /* mask learned from authenticated packet */
};

enum awg_compat_mode {
	AWG_COMPAT_OFF = 0,	/* plain upstream behaviour */
	AWG_COMPAT_ON = 1,	/* detect older peers, probe AWG versions */
	AWG_COMPAT_PROBE_WG = 2	/* additionally probe vanilla WireGuard */
};

extern unsigned int awg_compat_mode;

static inline u8 awg_peer_lacks(const struct wg_peer *peer)
{
	if (unlikely(!READ_ONCE(awg_compat_mode)))
		return 0;
	return READ_ONCE(peer->awg_compat) & AWG_LACK_ALL;
}

/* Features a received packet lacks, as far as they could be observed. */
static inline u8 awg_skb_lacks(const struct sk_buff *skb)
{
	u8 lacks = PACKET_CB(skb)->awg_lacks;

	/* Handshake messages do not reveal S3/S4. Fixed headers mean AWG 1.x,
	 * which has no S3/S4 either.
	 */
	if (!(PACKET_CB(skb)->awg_known & AWG_LACK_S34) &&
	    (lacks & AWG_LACK_RANGE))
		lacks |= AWG_LACK_S34;
	return lacks;
}

static inline u32 awg_header(u8 lacks, u32_range_t range, u32 wg_type)
{
	if (unlikely(lacks & AWG_LACK_AWG))
		return wg_type;
	if (unlikely(lacks & AWG_LACK_RANGE))
		return u32_range_lo(range);
	return u32_range_pick_one(range);
}

/* S1/S2 */
static inline u16 awg_padding(u8 lacks, u16 padding)
{
	return unlikely(lacks & AWG_LACK_AWG) ? 0 : padding;
}

/* S3/S4 */
static inline u16 awg_padding_s34(u8 lacks, u16 padding)
{
	return unlikely(lacks & (AWG_LACK_AWG | AWG_LACK_S34)) ? 0 : padding;
}

static inline bool awg_has_hp(u8 lacks)
{
	return likely(!(lacks & (AWG_LACK_AWG | AWG_LACK_HP)));
}

static inline bool awg_has_v3(u8 lacks)
{
	return likely(!(lacks & (AWG_LACK_AWG | AWG_LACK_V3)));
}

/* Called right after awg_determine_type_and_padding(). Falls back to the
 * packet shapes of older peers when the device configuration did not match,
 * and records the observed shape in PACKET_CB(). Returns the header length
 * (0 to drop) and updates padding, type and whether to remove header
 * protection.
 */
size_t awg_compat_classify(struct sk_buff *skb, struct wg_device *wg,
			   const struct chacha_state *state, bool *protected,
			   const u8 hash[4], size_t header_len, u16 *padding,
			   u32 *type);

/* Update the peer's mask from a received packet. The packet must have been
 * authenticated: a consumed handshake message or a decrypted, non-replayed
 * transport packet.
 */
void awg_compat_learn(struct wg_peer *peer, const struct sk_buff *skb);

#endif /* _AWG_FALLBACK_H */
