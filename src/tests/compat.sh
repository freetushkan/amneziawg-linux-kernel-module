#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Protocol fallback test: one AmneziaWG server speaking the full protocol
# (header protection, random trailers, content padding, S1-S4, wide H
# ranges) and clients of every older generation, each in its own netns:
#
#   c3     AmneziaWG 3.x, same configuration as the server
#   c3nohp AmneziaWG 3.x without header protection
#   c2     AmneziaWG 2.x: ranges, S1-S4
#   c2nos  AmneziaWG 2.x without S3/S4
#   c1     AmneziaWG 1.x: fixed headers (range low bounds), S1/S2
#   wg     vanilla WireGuard (in-tree wireguard.ko, wg tool)
#
# The AWG clients are emulated by this module with the matching
# configuration. Run as root with amneziawg loaded:
#
#   AWG=/path/to/awg WG=/path/to/wg ./compat.sh
#
# Checks:
#   1. client-initiated handshakes: every client gets through, the server
#      logs the expected protocol for each peer, clients log nothing (the
#      server answers in their own format);
#   2. no loss for older peers although the wide H4 range makes a large
#      share of their transport packets fit the server's format as well;
#   3. server-initiated handshakes to peers it has never heard from;
#   4. compat=0 restores upstream behaviour: only c3 gets through.

set -e
AWG=${AWG:-awg}
WG=${WG:-wg}
PARAM=/sys/module/amneziawg/parameters/compat
CLIENTS="c3 c3nohp c2 c2nos c1 wg"
failed=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; failed=1; }
n() { ip netns exec "$@"; }

cleanup() {
	set +e
	for ns in srv $CLIENTS; do ip netns del $ns 2>/dev/null; done
}
trap cleanup EXIT
cleanup

H1=100000000-1100000000
H2=1200000000-2200000000
H3=2300000000-2400000000
H4=2500000000-3500000000	# ~23% of the u32 space: lots of ambiguity
S="S1 = 40
S2 = 60"
S34="S3 = 30
S4 = 20"
JUNK="Jc = 3
Jmin = 40
Jmax = 70"
HPK=$($AWG genkey)

srv_key=$($AWG genkey); srv_pub=$(echo $srv_key | $AWG pubkey)
declare -A key pub idx
i=2
for c in $CLIENTS; do
	key[$c]=$($AWG genkey); pub[$c]=$(echo ${key[$c]} | $AWG pubkey)
	idx[$c]=$i; i=$((i + 1))
done

device_conf() { # $1 = generation
	case $1 in
	c3) printf '%s\n%s\n%s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\nHeaderProtectionKey = %s\nRandomTrailers = on\nContentPaddingAddition = 16-64\n' \
		"$JUNK" "$S" "$S34" $H1 $H2 $H3 $H4 $HPK ;;
	c3nohp) printf '%s\n%s\n%s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\nRandomTrailers = on\nContentPaddingAddition = 16-64\n' \
		"$JUNK" "$S" "$S34" $H1 $H2 $H3 $H4 ;;
	c2) printf '%s\n%s\n%s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' \
		"$JUNK" "$S" "$S34" $H1 $H2 $H3 $H4 ;;
	c2nos) printf '%s\n%s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' \
		"$JUNK" "$S" $H1 $H2 $H3 $H4 ;;
	c1) printf '%s\n%s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' \
		"$JUNK" "$S" ${H1%-*} ${H2%-*} ${H3%-*} ${H4%-*} ;;
	esac
}

setup_server() { # $1 = with client endpoints
	n srv ip link del awgs 2>/dev/null || true
	n srv ip link add awgs type amneziawg
	{
		printf '[Interface]\nPrivateKey = %s\nListenPort = 51820\n' $srv_key
		device_conf c3
		for c in $CLIENTS; do
			printf '[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.0.%s/32\n' ${pub[$c]} ${idx[$c]}
			[ -n "$1" ] && printf 'Endpoint = 192.168.%s.2:51820\n' ${idx[$c]}
		done
	} > /tmp/awgs.conf
	n srv $AWG setconf awgs /tmp/awgs.conf
	n srv ip addr add 10.0.0.1/24 dev awgs
	n srv ip link set awgs up
}

ip netns add srv
n srv ip link set lo up
for c in $CLIENTS; do
	ip netns add $c
	n $c ip link set lo up
	ip link add v$c netns srv type veth peer name eth0 netns $c
	n srv ip addr add 192.168.${idx[$c]}.1/24 dev v$c
	n srv ip link set v$c up
	n $c ip addr add 192.168.${idx[$c]}.2/24 dev eth0
	n $c ip link set eth0 up
	if [ $c = wg ]; then
		n $c ip link add awg$c type wireguard
		printf '[Interface]\nPrivateKey = %s\nListenPort = 51820\n' ${key[$c]} > /tmp/$c.conf
		TOOL=$WG
	else
		n $c ip link add awg$c type amneziawg
		{ printf '[Interface]\nPrivateKey = %s\nListenPort = 51820\n' ${key[$c]}; device_conf $c; } > /tmp/$c.conf
		TOOL=$AWG
	fi
	printf '[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.0.0/24\nEndpoint = 192.168.%s.1:51820\n' \
		$srv_pub ${idx[$c]} >> /tmp/$c.conf
	n $c $TOOL setconf awg$c /tmp/$c.conf
	n $c ip addr add 10.0.0.${idx[$c]}/24 dev awg$c
	n $c ip link set awg$c up
done

expect_proto() { # $1 = client, prints the expected log suffix
	case $1 in
	c3) echo "" ;;
	c3nohp) echo "AmneziaWG 3.x without header protection" ;;
	c2) echo "AmneziaWG 2.x" ;;
	c2nos) echo "AmneziaWG 2.x without S3/S4" ;;
	c1) echo "AmneziaWG 1.x" ;;
	wg) echo "WireGuard" ;;
	esac
}

check_logs() { # $1 = dmesg offset (lines)
	local log c want got
	log=$(dmesg | tail -n +$(($1 + 1)))
	for c in $CLIENTS; do
		want=$(expect_proto $c)
		got=$(echo "$log" | grep "awgs: peer .* (192.168.${idx[$c]}.2:" | tail -1 | sed 's/.* speaks //')
		if [ "$got" = "$want" ]; then
			pass "server sees $c as '${want:-full protocol}'"
		else
			fail "server sees $c as '$got', expected '$want'"
		fi
	done
	if echo "$log" | grep -E "awgc[0-9a-z]+: peer .* speaks" >/dev/null; then
		fail "a client saw the server fall back:"
		echo "$log" | grep -E "awgc[0-9a-z]+: peer .* speaks"
	else
		pass "every client got answers in its own format"
	fi
}

ping_until() { # $1 = netns, $2 = address, $3 = seconds
	local end=$((SECONDS + $3))
	while [ $SECONDS -lt $end ]; do
		n $1 ping -c 1 -W 1 $2 >/dev/null 2>&1 && return 0
	done
	return 1
}

echo 1 > $PARAM

echo "1. Client-initiated handshakes"
setup_server
mark=$(dmesg | wc -l)
for c in $CLIENTS; do
	if ping_until $c 10.0.0.1 15; then pass "$c reaches the server"; else fail "$c cannot reach the server"; fi
done
check_logs $mark

echo "2. No loss with ambiguous transport headers"
for c in $CLIENTS; do
	loss=$(n $c ping -q -c 300 -i 0.01 -s 1000 10.0.0.1 | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
	if [ "$loss" = "0" ]; then pass "$c: 300 pings, 0% loss"; else fail "$c: ${loss:-?}% loss"; fi
done

echo "3. Server-initiated handshakes to unknown peers (compat=2)"
echo 2 > $PARAM
setup_server endpoints
mark=$(dmesg | wc -l)
pids=
for c in $CLIENTS; do
	( ping_until srv 10.0.0.${idx[$c]} 45 && echo ok > /tmp/r.$c || echo no > /tmp/r.$c ) &
	pids="$pids $!"
done
wait $pids
for c in $CLIENTS; do
	if [ "$(cat /tmp/r.$c)" = ok ]; then pass "server reaches $c"; else fail "server cannot reach $c"; fi
done
check_logs $mark

echo "4. compat=0 is upstream behaviour"
echo 0 > $PARAM
setup_server
for c in $CLIENTS; do	# drop the clients' sessions
	n $c ip link set awg$c down
	n $c ip link set awg$c up
done
for c in $CLIENTS; do
	if ping_until $c 10.0.0.1 8; then r=ok; else r=no; fi
	if [ $c = c3 ]; then want=ok; else want=no; fi
	if [ $r = $want ]; then pass "$c: $([ $r = ok ] && echo connects || echo rejected)"; else fail "$c: got $r, expected $want"; fi
done
echo 1 > $PARAM

[ $failed = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $failed
