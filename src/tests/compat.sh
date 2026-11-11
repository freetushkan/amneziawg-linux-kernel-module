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
# The AWG clients use the matching configuration on CLIENT_KIND (default:
# this module). For a strict test build upstream as a second module with
# another name and genetlink family, plus awg tools for that family, and
# pass CLIENT_KIND/CLIENT_AWG: upstream only accepts its own format and
# does not announce itself, so the server has to get every format right
# and learn from packet shapes alone.
#
# Run as root with amneziawg loaded:
#
#   AWG=/path/to/awg WG=/path/to/wg [CLIENT_KIND=awgup CLIENT_AWG=awgup] ./compat.sh
#
# Checks:
#   1. client-initiated handshakes: every client gets through, the server
#      logs the expected protocol for each peer, clients log nothing (the
#      server answers in their own format);
#   2. no loss for older peers although the wide H4 range makes a large
#      share of their transport packets fit the server's format as well;
#   3. server-initiated handshakes to peers it has never heard from;
#   4. compat=0 restores upstream behaviour: only c3 gets through;
#   5. two hosts running this module do not drag each other down to an
#      older format when one of them probed while the other was down.

set -e
AWG=${AWG:-awg}
WG=${WG:-wg}
CLIENT_KIND=${CLIENT_KIND:-amneziawg}
CLIENT_AWG=${CLIENT_AWG:-$AWG}
PARAM=/sys/module/amneziawg/parameters/compat
CLIENTS=${CLIENTS:-"c3 c3nohp c2 c2nos c1 wg"}
TESTS=${TESTS:-"1 2 3 4 5"}
want() { [[ " $TESTS " == *" $1 "* ]]; }
failed=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; }
known() { printf '  \e[33mKNOWN\e[0m %s\n' "$*"; }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; failed=1; }
n() { ip netns exec "$@"; }

cleanup() {
	set +e
	for ns in srv $CLIENTS smart; do ip netns del $ns 2>/dev/null; done
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
smart_key=$($AWG genkey); smart_pub=$(echo $smart_key | $AWG pubkey)
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
		printf '[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.0.20/32\n' $smart_pub
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
		n $c ip link add awg$c type $CLIENT_KIND
		{ printf '[Interface]\nPrivateKey = %s\nListenPort = 51820\n' ${key[$c]}; device_conf $c; } > /tmp/$c.conf
		TOOL=$CLIENT_AWG
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

if want 1; then
echo "1. Client-initiated handshakes"
setup_server
mark=$(dmesg | wc -l)
for c in $CLIENTS; do
	if ping_until $c 10.0.0.1 30; then pass "$c reaches the server"; else fail "$c cannot reach the server"; fi
done
check_logs $mark

fi

if want 2; then
echo "2. No loss with ambiguous transport headers"
for c in $CLIENTS; do
	loss=$(n $c ping -q -c 300 -i 0.01 -s 1000 10.0.0.1 | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
	if [ "$loss" = "0" ]; then
		pass "$c: 300 pings, 0% loss"
	elif [ $CLIENT_KIND != amneziawg ] && [[ $c == c3* ]]; then
		# Upstream itself tests a transport packet as an initiation and a
		# response first when RandomTrailers is on, so with wide H1/H2 it
		# drops a share of the server's packets. Fixed on this side by
		# "receive: resolve packets that fit more than one shape".
		known "$c: ${loss}% loss in the upstream client (RandomTrailers + wide H1/H2)"
	else
		fail "$c: ${loss:-?}% loss"
	fi
done

fi

if want 3; then
echo "3. Server-initiated handshakes to unknown peers (compat=2)"
echo 2 > $PARAM
setup_server endpoints
mark=$(dmesg | wc -l)
pids=
for c in $CLIENTS; do
	( ping_until srv 10.0.0.${idx[$c]} 60 && echo ok > /tmp/r.$c || echo no > /tmp/r.$c ) &
	pids="$pids $!"
done
wait $pids
for c in $CLIENTS; do
	if [ "$(cat /tmp/r.$c)" = ok ]; then pass "server reaches $c"; else fail "server cannot reach $c"; fi
done
check_logs $mark

fi

if want 4; then
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
fi

if want 5; then
echo "5. No mutual downgrade between two hosts running the fallback"
setup_server
ip netns add smart
n smart ip link set lo up
ip link add vsmart netns srv type veth peer name eth0 netns smart
n srv ip addr add 192.168.20.1/24 dev vsmart
n srv ip link set vsmart up
n smart ip addr add 192.168.20.2/24 dev eth0
n smart ip link set eth0 up
n smart ip link add awgp type amneziawg
{
	printf '[Interface]\nPrivateKey = %s\n' $smart_key
	device_conf c3
	printf '[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.0.0/24\nEndpoint = 192.168.20.1:51820\n' $srv_pub
} > /tmp/smart.conf
n smart $AWG setconf awgp /tmp/smart.conf
n smart ip addr add 10.0.0.20/24 dev awgp
n smart ip link set awgp up
mark=$(dmesg | wc -l)
n srv ip link set awgs down	# the client starts while the server is down,
( ping_until smart 10.0.0.1 60 && echo ok > /tmp/r.smart || echo no > /tmp/r.smart ) &
sleep 17			# probes older formats,
n srv ip link set awgs up	# and the server comes back
wait
if [ "$(cat /tmp/r.smart)" = ok ]; then pass "client reaches the restarted server"; else fail "client cannot reach the restarted server"; fi
n smart ping -q -c 50 -i 0.02 10.0.0.1 >/dev/null 2>&1 || true
log=$(dmesg | tail -n +$((mark + 1)) | grep -E "awgp: peer|awgs: peer .*192.168.20.2:" | grep -v "as configured" || true)
if [ -z "$log" ]; then pass "both sides use the full protocol"; else fail "fallback stuck:"; echo "$log"; fi
fi

[ $failed = 0 ] && echo "ALL PASSED" || echo "SOME TESTS FAILED"
exit $failed
