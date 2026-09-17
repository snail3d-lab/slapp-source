#!/bin/bash
# e2e-test.sh — the whole suite: bridge → daemon → real pi pane → reply → phone view.
# Run any time; exits nonzero on the first red X.
T=$(python3 -c "
import json
d = json.load(open('$HOME/.monocle/bridge/devices.json'))
print(d['devices']['MONOCLE-IOS-F441']['token'])")
BRIDGE=http://127.0.0.1:8651
DAEMON=http://127.0.0.1:8123
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check(){ if [ "$2" = "1" ]; then ok "$1"; else bad "$1"; fi }

echo "── 1. bridge alive ──"
H=$(curl -s -m 4 $BRIDGE/health | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
check "bridge /health ok" "$([ "$H" = "True" ] && echo 1)"

echo "── 2. daemon alive, every session ready with a real pane ──"
S=$(curl -s -m 4 $DAEMON/api/health)
BADPHASES=$(echo "$S" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(','.join(s['slug'] for s in d['sessions'] if s['slug'] != 'slapp-itself' and s['phase'] != 'ready'))")
check "all sessions phase=ready (bad: '$BADPHASES')" "$([ -z "$BADPHASES" ] && echo 1)"
PANES=$(herdr pane list 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
ps = d.get('result',{}).get('panes',[])
print(len([p for p in ps if (p.get('terminal_title') or '').startswith('π - ') and ' - ' in (p.get('terminal_title') or '') and p.get('cwd','').startswith('$HOME/Desktop')]))")
check "herdr shows slapp pi panes ($PANES found)" "$([ "${PANES:-0}" -ge 8 ] && echo 1)"

echo "── 3. model backend up ──"
MC=$(curl -s -m 6 -o /dev/null -w "%{http_code}" http://YOUR_HOST_TAILNET_IP:8888/health)
check "snail-top (bs2:8888) answering [$MC]" "$([ "$MC" = "200" ] && echo 1)"

echo "── 4. round trip: phone words → real pane → agent reply ──"
STAMP="e2e-$(date +%H%M%S)"
CID=$(curl -s -m 4 -H "Authorization: Bearer $T" $BRIDGE/channels | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(next(c['id'] for c in d['channels'] if c['name']=='monocle'))")
R=$(curl -s -m 8 -X POST $BRIDGE/capture -H "Authorization: Bearer $T" -F "mode=text" -F "channel=$CID" -F "text=$STAMP: reply with the single word RECEIVED")
check "capture accepted" "$(echo "$R" | grep -q '"accepted": true' && echo 1)"
REPLY=""
for i in $(seq 1 24); do
  sleep 5
  REPLY=$(curl -s -m 4 -H "Authorization: Bearer $T" "$BRIDGE/channels/$CID/history?n=4" | python3 -c "
import json,sys
d = json.load(sys.stdin)
es = d.get('entries',[])
for e in reversed(es):
    if e['role']=='agent' and '$STAMP' not in e['text']:
        print(e['text'][:80]); break" 2>/dev/null)
  [ -n "$REPLY" ] && break
done
check "agent replied within 2 min: '$REPLY'" "$([ -n "$REPLY" ] && echo 1)"

echo "── 5. the words appeared in the REAL pane (herdr) ──"
PANE_LINE=$(herdr pane list 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
ps = d.get('result',{}).get('panes',[])
print(next((p['pane_id'] for p in ps if (p.get('terminal_title') or '') == 'π - monocle - monocle'), ''))")
FOUND=$(herdr pane read "$PANE_LINE" 2>/dev/null | grep -c "$STAMP")
check "pane $PANE_LINE shows the typed words ($FOUND hits)" "$([ "${FOUND:-0}" -ge 1 ] && echo 1)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
