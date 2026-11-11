// SPDX-License-Identifier: GPL-2.0
/*
 * Per-peer protocol fallback for older AmneziaWG versions and WireGuard.
 * See awg_fallback.h for the overview.
 */

#include "awg_fallback.h"
#include "device.h"
#include "messages.h"

#include <linux/moduleparam.h>
#include <linux/skbuff.h>

unsigned int awg_compat_mode = AWG_COMPAT_ON;
module_param_named(compat, awg_compat_mode, uint, 0644);
MODULE_PARM_DESC(compat, "Fallback for peers running older protocol versions: 0 - off (upstream behaviour), 1 - detect AmneziaWG 1.x/2.x peers (default), 2 - also probe vanilla WireGuard when initiating to an unknown peer");

/*
 * Receive side.
 *
 * Upstream classifies a packet with the device configuration only. When that
 * fails, try the shapes older peers produce:
 *
 *   - AmneziaWG 3.x without header protection;
 *   - AmneziaWG 1.x/2.x without S3/S4 (and without trailers);
 *   - vanilla WireGuard.
 *
 * AmneziaWG 2.x with S3/S4 is covered by the first one, fixed headers of
 * AmneziaWG 1.x are within the device ranges by convention (H = range low
 * bound).
 */

struct awg_shape {
	u16 padding[4];	/* S1-S4 */
	bool hp;	/* header protection */
	bool trailers;	/* handshake messages may carry random trailers */
	bool wg;	/* vanilla WireGuard message types */
};

struct awg_match {
	const struct awg_shape *shape;
	size_t header_len;
	u32 type;	/* MESSAGE_* */
	u32 value;	/* decoded header value */
	u16 padding;
	u8 msg;		/* index into awg_msgs */
};

static const struct {
	u32 type;
	size_t len;		/* full message length */
	size_t header_len;	/* what prepare_skb_header() reports */
} awg_msgs[4] = {
	{ MESSAGE_HANDSHAKE_INITIATION,
	  sizeof(struct message_handshake_initiation),
	  sizeof(struct message_handshake_initiation) },
	{ MESSAGE_HANDSHAKE_RESPONSE,
	  sizeof(struct message_handshake_response),
	  sizeof(struct message_handshake_response) },
	{ MESSAGE_HANDSHAKE_COOKIE,
	  sizeof(struct message_handshake_cookie),
	  sizeof(struct message_handshake_cookie) },
	{ MESSAGE_DATA, MESSAGE_MINIMUM_LENGTH, sizeof(struct message_data) }
};

static u32_range_t awg_range(const struct wg_device *wg, u8 msg)
{
	switch (msg) {
	case 0:
		return wg->init_header;
	case 1:
		return wg->resp_header;
	case 2:
		return wg->cookie_header;
	default:
		return wg->transport_header;
	}
}

static u8 awg_msg_index(u32 type)
{
	return type == MESSAGE_HANDSHAKE_INITIATION ? 0 :
	       type == MESSAGE_HANDSHAKE_RESPONSE ? 1 :
	       type == MESSAGE_HANDSHAKE_COOKIE ? 2 : 3;
}

static u32 awg_read_value(struct sk_buff *skb, u16 padding, bool hp,
			  const u8 hash[4])
{
	u8 buf[4], *p = skb_header_pointer(skb, padding, sizeof(buf), buf);
	u32 value;

	if (unlikely(!p))
		return 0;
	value = get_unaligned_le32(p);
	return hp ? value ^ get_unaligned_le32(hash) : value;
}

/* Mirrors awg_determine_type_and_padding() for an arbitrary shape. */
static bool awg_try(struct sk_buff *skb, const struct wg_device *wg,
		    const struct awg_shape *s, const u8 hash[4],
		    struct awg_match *m)
{
	u8 i;

	for (i = 0; i < ARRAY_SIZE(awg_msgs); ++i) {
		unsigned int expected = s->padding[i] + awg_msgs[i].len;
		u8 buf[4], *p;
		u32 value;

		if ((i == 3 || s->trailers) ? skb->len < expected :
					      skb->len != expected)
			continue;
		p = skb_header_pointer(skb, s->padding[i], sizeof(buf), buf);
		if (!p)
			continue;
		value = get_unaligned_le32(p);
		if (s->hp)
			value ^= get_unaligned_le32(hash);
		if (s->wg ? value != awg_msgs[i].type :
			    !u32_range_contains(awg_range(wg, i), value))
			continue;

		m->shape = s;
		m->msg = i;
		m->type = awg_msgs[i].type;
		m->header_len = awg_msgs[i].header_len;
		m->padding = s->padding[i];
		m->value = value;
		return true;
	}
	return false;
}

/* Record which features the packet shows or lacks, for awg_compat_learn(). */
static void awg_set_shape(struct sk_buff *skb, const struct wg_device *wg,
			  const struct awg_match *m)
{
	const struct awg_shape *s = m->shape;
	u8 lacks = 0, known = AWG_LACK_AWG;

	if (s->wg) {
		lacks = known = AWG_LACK_ALL;
		goto out;
	}

	if (s->hp) {
		/* Header protection needs S1-S4 and came with AWG 3.x. */
		known |= AWG_LACK_HP | AWG_LACK_S34 | AWG_LACK_V3;
	} else if (wg->header_protection.has_protection) {
		known |= AWG_LACK_HP;
		lacks |= AWG_LACK_HP;
	}

	if (m->type == MESSAGE_HANDSHAKE_INITIATION ||
	    m->type == MESSAGE_HANDSHAKE_RESPONSE) {
		u32_range_t range = awg_range(wg, m->msg);

		if (u32_range_lo(range) != u32_range_hi(range)) {
			known |= AWG_LACK_RANGE;
			if (m->value == u32_range_lo(range))
				lacks |= AWG_LACK_RANGE;
		}
		if (!s->hp && wg->random_trailers) {
			known |= AWG_LACK_V3;
			if (skb->len == m->padding + awg_msgs[m->msg].len)
				lacks |= AWG_LACK_V3;
		}
	} else if (!s->hp) {
		u16 padding = m->type == MESSAGE_DATA ? wg->transport_padding :
							wg->cookie_padding;

		if (padding) {
			known |= AWG_LACK_S34;
			if (!m->padding)
				lacks |= AWG_LACK_S34;
		}
	}
out:
	PACKET_CB(skb)->awg_lacks = lacks;
	PACKET_CB(skb)->awg_known = known;
}

size_t awg_compat_classify(struct sk_buff *skb, struct wg_device *wg,
			   const struct chacha_state *state, bool *protected,
			   const u8 hash[4], size_t header_len, u16 *padding,
			   u32 *type)
{
	struct awg_shape shapes[4] = {
		[0] = {
			.padding = { wg->init_padding, wg->resp_padding,
				     wg->cookie_padding, wg->transport_padding },
			.hp = *protected,
			.trailers = wg->random_trailers
		}
	};
	struct awg_match m;
	int i, n = 1;

	PACKET_CB(skb)->awg_lacks = 0;
	PACKET_CB(skb)->awg_known = 0;
	if (!READ_ONCE(awg_compat_mode))
		return header_len;

	if (header_len) {
		m.shape = &shapes[0];
		m.msg = awg_msg_index(*type);
		m.type = *type;
		m.header_len = header_len;
		m.padding = *padding;
		m.value = m.msg < 2 ? awg_read_value(skb, *padding, *protected,
						     hash) : 0;
		goto found;
	}

	/* AWG 3.x without header protection */
	if (*protected) {
		shapes[n] = shapes[0];
		shapes[n++].hp = false;
	}
	/* AWG 1.x/2.x without S3/S4 */
	if (wg->cookie_padding || wg->transport_padding)
		shapes[n++] = (struct awg_shape){
			.padding = { wg->init_padding, wg->resp_padding }
		};
	/* WireGuard */
	shapes[n++] = (struct awg_shape){ .wg = true };

	for (i = 1; i < n; ++i) {
		if (awg_try(skb, wg, &shapes[i], hash, &m))
			goto found;
	}
	return 0;

found:
	awg_set_shape(skb, wg, &m);
	*protected = m.shape->hp;
	*padding = m.padding;
	*type = m.type;
	return m.header_len;
}
