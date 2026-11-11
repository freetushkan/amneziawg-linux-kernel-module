// SPDX-License-Identifier: GPL-2.0
/*
 * Per-peer protocol fallback for older AmneziaWG versions and WireGuard.
 * See awg_fallback.h for the overview.
 */

#include "awg_fallback.h"
#include "device.h"
#include "messages.h"
#include "peerlookup.h"

#include <crypto/algapi.h>
#include <crypto/blake2s.h>
#include <crypto/chacha.h>
#include <linux/moduleparam.h>
#include <linux/rculist.h>
#include <linux/skbuff.h>

unsigned int awg_compat_mode = AWG_COMPAT_ON;
module_param_named(compat, awg_compat_mode, uint, 0644);
/* Set once any peer turned out to lack a feature. Until then packets that
 * match the device configuration are not checked for other shapes.
 */
static bool awg_lacking_seen;

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

static bool awg_same(const struct awg_match *a, const struct awg_match *b)
{
	return a->type == b->type && a->padding == b->padding &&
	       a->shape->hp == b->shape->hp;
}

#define AWG_MAX_MATCHES 8

/* Mirrors awg_determine_type_and_padding() for an arbitrary shape, but
 * appends every message type the packet fits, not just the first one.
 * Returns the new number of matches.
 */
static int awg_try(struct sk_buff *skb, const struct wg_device *wg,
		   const struct awg_shape *s, const u8 hash[4],
		   struct awg_match *matches, int n)
{
	u8 i;
	int j;

	for (i = 0; i < ARRAY_SIZE(awg_msgs) && n < AWG_MAX_MATCHES; ++i) {
		struct awg_match *m = &matches[n];
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
		for (j = 0; j < n && !awg_same(&matches[j], m); ++j)
			;
		if (j == n)
			++n;
	}
	return n;
}

/*
 * A packet may fit more than one (shape, message type) pair: the 4 bytes a
 * pair takes for the header are effectively random for packets of another
 * pair, so they fall into a header range with probability width / 2^32,
 * which is not small for wide ranges. This already happens within the
 * device configuration alone: with random trailers a transport packet is
 * first tested as an initiation and a response.
 *
 * Pick the pair under which the packet makes sense, cheapest checks first:
 * the receiver index of transport packets, cookie replies and responses
 * must belong to us, and an initiation must carry a valid mac1.
 */

/* Remove header protection from a copy of the message start. */
static void awg_unprotect(const struct chacha_state *state, u8 *buf, size_t len)
{
	struct chacha_state st = *state;

	chacha20_crypt(&st, buf, buf, len);
	memzero_explicit(&st, sizeof(st));
}

static bool awg_index_valid(struct sk_buff *skb, struct wg_device *wg,
			    const struct awg_match *m,
			    const struct chacha_state *state,
			    size_t offset, enum index_hashtable_type type)
{
	struct index_hashtable *table = wg->index_hashtable;
	struct index_hashtable_entry *entry;
	u8 buf[12];
	__le32 index;
	bool found = false;

	if (skb_copy_bits(skb, m->padding, buf, offset + sizeof(index)))
		return false;
	if (m->shape->hp)
		awg_unprotect(state, buf, offset + sizeof(index));
	memcpy(&index, buf + offset, sizeof(index));

	/* Same lookup as wg_index_hashtable_lookup(), without taking refs */
	rcu_read_lock_bh();
	hlist_for_each_entry_rcu_bh(entry,
		&table->hashtable[(__force u32)index &
				  (HASH_SIZE(table->hashtable) - 1)],
		index_hash) {
		if (entry->index == index) {
			found = entry->type & type;
			break;
		}
	}
	rcu_read_unlock_bh();
	return found;
}

static bool awg_mac1_valid(struct sk_buff *skb, struct wg_device *wg,
			   const struct awg_match *m,
			   const struct chacha_state *state)
{
	u8 msg[sizeof(struct message_handshake_initiation)];
	u8 mac1[COOKIE_LEN];
	size_t len = awg_msgs[m->msg].len;
	bool ret;

	if (skb_copy_bits(skb, m->padding, msg, len))
		return false;
	if (m->shape->hp)
		awg_unprotect(state, msg, len);
	/* Same as compute_mac1() in cookie.c */
	blake2s(wg->cookie_checker.message_mac1_key, NOISE_SYMMETRIC_KEY_LEN,
		msg, len - sizeof(struct message_macs), mac1, COOKIE_LEN);
	ret = !crypto_memneq(mac1, msg + len - sizeof(struct message_macs),
			     COOKIE_LEN);
	memzero_explicit(msg, sizeof(msg));
	return ret;
}

static bool awg_valid(struct sk_buff *skb, struct wg_device *wg,
		      const struct awg_match *m,
		      const struct chacha_state *state)
{
	switch (m->type) {
	case MESSAGE_DATA:
		return awg_index_valid(skb, wg, m, state,
				       offsetof(struct message_data, key_idx),
				       INDEX_HASHTABLE_KEYPAIR);
	case MESSAGE_HANDSHAKE_COOKIE:
		return awg_index_valid(skb, wg, m, state,
				       offsetof(struct message_handshake_cookie,
						receiver_index),
				       INDEX_HASHTABLE_HANDSHAKE);
	case MESSAGE_HANDSHAKE_RESPONSE:
		return awg_index_valid(skb, wg, m, state,
				       offsetof(struct message_handshake_response,
						receiver_index),
				       INDEX_HASHTABLE_HANDSHAKE);
	default:
		return awg_mac1_valid(skb, wg, m, state);
	}
}

static const struct awg_match *awg_pick(struct sk_buff *skb,
					struct wg_device *wg,
					const struct awg_match *matches, int n,
					const struct chacha_state *state)
{
	static const u32 order[] = {
		MESSAGE_DATA, MESSAGE_HANDSHAKE_COOKIE,
		MESSAGE_HANDSHAKE_RESPONSE, MESSAGE_HANDSHAKE_INITIATION
	};
	int i, j;

	for (i = 0; i < ARRAY_SIZE(order); ++i) {
		for (j = 0; j < n; ++j) {
			if (matches[j].type == order[i] &&
			    awg_valid(skb, wg, &matches[j], state))
				return &matches[j];
		}
	}
	return &matches[0];
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
	struct awg_match matches[AWG_MAX_MATCHES];
	const struct awg_match *m = matches;
	int i, n = 0, shapes_n = 1;

	PACKET_CB(skb)->awg_lacks = 0;
	PACKET_CB(skb)->awg_known = 0;
	if (!READ_ONCE(awg_compat_mode))
		return header_len;

	if (header_len) {
		matches[0].shape = &shapes[0];
		matches[0].msg = awg_msg_index(*type);
		matches[0].type = *type;
		matches[0].header_len = header_len;
		matches[0].padding = *padding;
		matches[0].value = matches[0].msg < 2 ?
			awg_read_value(skb, *padding, *protected, hash) : 0;
		n = 1;

		if (!READ_ONCE(awg_lacking_seen)) {
			/* Fast path. Only a handshake message with trailing
			 * bytes may as well be a transport packet.
			 */
			if (*type == MESSAGE_DATA ||
			    skb->len == *padding + awg_msgs[matches[0].msg].len)
				goto out;
			n = awg_try(skb, wg, &shapes[0], hash, matches, n);
			goto pick;
		}
		n = awg_try(skb, wg, &shapes[0], hash, matches, n);
	}

	/* AWG 3.x without header protection */
	if (*protected) {
		shapes[shapes_n] = shapes[0];
		shapes[shapes_n++].hp = false;
	}
	/* AWG 1.x/2.x without S3/S4 */
	if (wg->cookie_padding || wg->transport_padding)
		shapes[shapes_n++] = (struct awg_shape){
			.padding = { wg->init_padding, wg->resp_padding }
		};
	/* WireGuard */
	shapes[shapes_n++] = (struct awg_shape){ .wg = true };

	for (i = 1; i < shapes_n; ++i)
		n = awg_try(skb, wg, &shapes[i], hash, matches, n);
	if (!n)
		return 0;
pick:
	if (n > 1)
		m = awg_pick(skb, wg, matches, n, state);
out:
	awg_set_shape(skb, wg, m);
	*protected = m->shape->hp;
	*padding = m->padding;
	*type = m->type;
	return m->header_len;
}

static void awg_log(const struct wg_peer *peer, u8 f)
{
	const char *proto, *extra = "";

	if (f & AWG_LACK_AWG) {
		proto = "WireGuard";
	} else if (f & AWG_LACK_RANGE) {
		proto = "AmneziaWG 1.x";
	} else if (f & AWG_LACK_V3) {
		proto = "AmneziaWG 2.x";
		if (f & AWG_LACK_S34)
			extra = " without S3/S4";
	} else if (f & AWG_LACK_HP) {
		proto = "AmneziaWG 3.x";
		extra = " without header protection";
	} else {
		proto = "AmneziaWG, as configured";
	}

	net_info_ratelimited("%s: peer %llu (%pISpfsc) speaks %s%s\n",
			     peer->device->dev->name, peer->internal_id,
			     &peer->endpoint.addr, proto, extra);
}

/*
 * Two hosts running this code would otherwise learn from each other's
 * degraded packets: one probes the other in an older format, the other
 * concludes the prober lacks those features and answers in that format, and
 * both stay there. So both announce what their own configuration lacks in
 * the first 4 bytes of the S1/S2 padding of handshake messages:
 *
 *   tag = BLAKE2s-32(key = receiver's mac1 key, handshake message)
 *   padding[0..2] = tag[0..2]
 *   padding[3] = tag[3] ^ (AWG_MARK_VERSION << 5 | lacks)
 *
 * To anyone without the receiver's public key these are random bytes, as
 * padding is supposed to be; older implementations ignore them.
 */
#define AWG_MARK_VERSION 1
#define AWG_MARK_LEN 4

static u8 awg_device_lacks(const struct wg_device *wg)
{
	u8 lacks = 0;

	if (!wg->header_protection.has_protection)
		lacks |= AWG_LACK_HP;
	if (!wg->random_trailers)
		lacks |= AWG_LACK_V3;
	if (!wg->cookie_padding && !wg->transport_padding)
		lacks |= AWG_LACK_S34;
	if (u32_range_lo(wg->init_header) == u32_range_hi(wg->init_header) &&
	    u32_range_lo(wg->resp_header) == u32_range_hi(wg->resp_header) &&
	    u32_range_lo(wg->cookie_header) == u32_range_hi(wg->cookie_header) &&
	    u32_range_lo(wg->transport_header) == u32_range_hi(wg->transport_header))
		lacks |= AWG_LACK_RANGE;
	return lacks;
}

void awg_compat_mark(struct wg_peer *peer, u8 *padding, size_t padding_len,
		     const void *msg, size_t len)
{
	u8 tag[AWG_MARK_LEN];

	if (!READ_ONCE(awg_compat_mode) || padding_len < AWG_MARK_LEN)
		return;
	down_read(&peer->latest_cookie.lock);
	blake2s(peer->latest_cookie.message_mac1_key, NOISE_SYMMETRIC_KEY_LEN,
		msg, len, tag, sizeof(tag));
	up_read(&peer->latest_cookie.lock);
	memcpy(padding, tag, AWG_MARK_LEN - 1);
	padding[AWG_MARK_LEN - 1] = tag[AWG_MARK_LEN - 1] ^
		(AWG_MARK_VERSION << 5 | awg_device_lacks(peer->device));
}

/* Called on a handshake message that was consumed successfully: skb->data
 * holds the plaintext message, the padding is right in front of it.
 */
static bool awg_read_mark(const struct wg_device *wg,
			  const struct sk_buff *skb, u8 *lacks)
{
	const u8 *p = skb->data - PACKET_CB(skb)->padding;
	u8 tag[AWG_MARK_LEN], v;

	if (PACKET_CB(skb)->padding < AWG_MARK_LEN || p < skb->head)
		return false;
	blake2s(wg->cookie_checker.message_mac1_key, NOISE_SYMMETRIC_KEY_LEN,
		skb->data, skb->len, tag, sizeof(tag));
	if (crypto_memneq(p, tag, AWG_MARK_LEN - 1))
		return false;
	v = p[AWG_MARK_LEN - 1] ^ tag[AWG_MARK_LEN - 1];
	if (v >> 5 != AWG_MARK_VERSION)
		return false;
	*lacks = v & AWG_LACK_ALL;
	return true;
}

void awg_compat_learn(struct wg_peer *peer, const struct sk_buff *skb)
{
	u8 known = PACKET_CB(skb)->awg_known;
	u8 lacks = PACKET_CB(skb)->awg_lacks & known;
	u8 old = READ_ONCE(peer->awg_compat), base, new, mark;
	bool handshake = PACKET_CB(skb)->type != MESSAGE_DATA;

	BUILD_BUG_ON(sizeof(struct packet_cb) > sizeof_field(struct sk_buff, cb));

	if (!known)	/* compat off */
		return;
	if (handshake && !(lacks & AWG_LACK_AWG) &&
	    awg_read_mark(peer->device, skb, &mark)) {
		/* The peer told us what it lacks: trust that over the shape
		 * of its packets, which reflects what it believes of us.
		 */
		new = mark | AWG_STATE_S34_SEEN | AWG_STATE_LEARNED |
		      AWG_STATE_MARKED;
		goto update;
	}
	base = old;
	if (old & AWG_STATE_MARKED) {
		if (!handshake)
			return;
		/* Unmarked handshake: the key is now used by something else. */
		base = 0;
	}

	new = (base & ~known) | lacks | AWG_STATE_LEARNED;
	if (known & AWG_LACK_S34) {
		new |= AWG_STATE_S34_SEEN;
	} else if (!(base & (AWG_STATE_S34_SEEN | AWG_STATE_LEARNED)) &&
		   (known & AWG_LACK_RANGE)) {
		/* Until a transport packet shows it, guess S3/S4 from the
		 * header kind: fixed headers mean AWG 1.x without S3/S4.
		 * Only on first contact, so a correction made by
		 * awg_compat_data_unanswered() sticks.
		 */
		new &= ~AWG_LACK_S34;
		if (lacks & AWG_LACK_RANGE)
			new |= AWG_LACK_S34;
	}
update:
	if (likely(new == old))
		return;

	WRITE_ONCE(peer->awg_compat, new);
	if (new & AWG_LACK_ALL)
		WRITE_ONCE(awg_lacking_seen, true);
	if (((new ^ old) & AWG_LACK_ALL) ||
	    ((new & ~old & (AWG_STATE_LEARNED | AWG_STATE_S34_SEEN)) &&
	     (new & AWG_LACK_ALL)))
		awg_log(peer, new);
}

/*
 * Initiating to a peer we have not heard from yet: its version is unknown,
 * so if the handshake goes unanswered, retry in the formats of older
 * versions in turn. WireGuard is only probed with compat=2, since it shows
 * a plain WireGuard handshake on the wire.
 */
static const u8 awg_probe_masks[] = {
	0,						/* as configured */
	AWG_LACK_HP | AWG_LACK_V3,			/* AWG 2.x */
	AWG_LACK_HP | AWG_LACK_V3 | AWG_LACK_RANGE |
		AWG_LACK_S34,				/* AWG 1.x */
	AWG_LACK_ALL					/* WireGuard */
};

void awg_compat_handshake_unanswered(struct wg_peer *peer)
{
	unsigned int mode = READ_ONCE(awg_compat_mode), n;

	if (!mode || (READ_ONCE(peer->awg_compat) & AWG_STATE_LEARNED))
		return;
	/* Own counter: timer_handshake_attempts is reset by every packet
	 * queued while the handshake is pending.
	 */
	n = ARRAY_SIZE(awg_probe_masks) - (mode < AWG_COMPAT_PROBE_WG);
	peer->awg_probe = (peer->awg_probe + 1) % n;
	WRITE_ONCE(peer->awg_compat, awg_probe_masks[peer->awg_probe]);
}

/*
 * We completed a handshake as the initiator, so the peer waits for our first
 * transport packet. If we do not know whether it uses S4 yet, confirm the
 * session with a second keepalive in the other S4 format: the peer drops the
 * one it cannot parse, answers the other, and its answer tells us.
 */
void awg_compat_confirm_session(struct wg_peer *peer)
{
	u8 f = READ_ONCE(peer->awg_compat);
	struct sk_buff *skb;

	if (!READ_ONCE(awg_compat_mode) || !peer->device->transport_padding ||
	    (f & (AWG_LACK_AWG | AWG_STATE_S34_SEEN)))
		return;
	skb = alloc_skb(DATA_PACKET_HEAD_ROOM + MESSAGE_MINIMUM_LENGTH,
			GFP_ATOMIC);
	if (unlikely(!skb))
		return;
	skb_reserve(skb, DATA_PACKET_HEAD_ROOM);
	skb->dev = peer->device->dev;
	PACKET_CB(skb)->mtu = skb->dev->mtu;
	PACKET_CB(skb)->is_keepalive = true;
	PACKET_CB(skb)->awg_lacks = AWG_LACK_S34;
	skb_queue_tail(&peer->staged_packet_queue, skb);
	wg_packet_send_staged_packets(peer);
}

/*
 * We sent transport packets after a handshake and got nothing back. If S4
 * was only guessed, the guess may be wrong: try the other way.
 */
void awg_compat_data_unanswered(struct wg_peer *peer)
{
	u8 f = READ_ONCE(peer->awg_compat);

	if (!READ_ONCE(awg_compat_mode) || !peer->device->transport_padding ||
	    !(f & AWG_STATE_LEARNED) ||
	    (f & (AWG_LACK_AWG | AWG_STATE_S34_SEEN)))
		return;
	WRITE_ONCE(peer->awg_compat, f ^ AWG_LACK_S34);
}
