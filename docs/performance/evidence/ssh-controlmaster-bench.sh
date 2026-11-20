#!/bin/bash
# 배포 스크립트가 배포 잡 하나당 SSH 연결을 3번(sync-deploy-files.sh, apply-ci-s3-env-remote.sh,
# deploy-remote.sh) 따로 여는 것과, ControlMaster/ControlPersist로 첫 연결을 재사용하는 것의
# 왕복 시간 차이를 로컬 sshd로 측정한다. 실제 EC2까지의 네트워크 왕복(RTT)은 포함하지 않는다 —
# 이 벤치마크는 "핸드셰이크·인증 자체의 고정 비용"만 격리해서 보여준다(loopback, RTT≈0).
# 실제 배포(리전 내 CI runner -> EC2)에서는 여기에 왕복마다 실제 네트워크 RTT가 추가로 얹히므로
# 실제 절감폭은 이 측정치보다 클 것으로 예상한다(가설, 이 스크립트로는 확인 불가).
set -euo pipefail

WORKDIR="${1:-/tmp/sshbench}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

ssh-keygen -q -t ed25519 -N '' -f "$WORKDIR/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$WORKDIR/client_key"
cp "$WORKDIR/client_key.pub" "$WORKDIR/authorized_keys"
chmod 600 "$WORKDIR/client_key" "$WORKDIR/authorized_keys"

cat > "$WORKDIR/sshd_config" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $WORKDIR/host_key
AuthorizedKeysFile $WORKDIR/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitRootLogin no
StrictModes no
PidFile $WORKDIR/sshd.pid
Subsystem sftp internal-sftp
EOF

/usr/sbin/sshd -f "$WORKDIR/sshd_config" -D &
SSHD_PID=$!
sleep 1

USERNAME="$(whoami)"
ssh-keyscan -p 2222 127.0.0.1 > "$WORKDIR/known_hosts" 2>/dev/null

COMMON_OPTS="-i $WORKDIR/client_key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$WORKDIR/known_hosts -o LogLevel=ERROR -p 2222"

TRIALS=30
BEFORE_LOG="$WORKDIR/before_times.txt"
AFTER_LOG="$WORKDIR/after_times.txt"
: > "$BEFORE_LOG"
: > "$AFTER_LOG"

echo "=== BEFORE: 3 separate cold SSH connections per trial (수정 전 스크립트와 동일 패턴) ==="
for i in $(seq 1 "$TRIALS"); do
  start=$(date +%s.%N)
  ssh $COMMON_OPTS "$USERNAME@127.0.0.1" "true"
  ssh $COMMON_OPTS "$USERNAME@127.0.0.1" "true"
  ssh $COMMON_OPTS "$USERNAME@127.0.0.1" "true"
  end=$(date +%s.%N)
  echo "$end - $start" | bc >> "$BEFORE_LOG"
done

echo "=== AFTER: ControlMaster/ControlPersist 공유 (수정본) ==="
for i in $(seq 1 "$TRIALS"); do
  CTRL_PATH="/tmp/bench-ssh-cm-$i-%C"
  MUX_OPTS="-o ControlMaster=auto -o ControlPersist=10s -o ControlPath=$CTRL_PATH"
  start=$(date +%s.%N)
  ssh $COMMON_OPTS $MUX_OPTS "$USERNAME@127.0.0.1" "true"
  ssh $COMMON_OPTS $MUX_OPTS "$USERNAME@127.0.0.1" "true"
  ssh $COMMON_OPTS $MUX_OPTS "$USERNAME@127.0.0.1" "true"
  end=$(date +%s.%N)
  echo "$end - $start" | bc >> "$AFTER_LOG"
  ssh $COMMON_OPTS $MUX_OPTS -O exit "$USERNAME@127.0.0.1" 2>/dev/null || true
done

kill "$SSHD_PID" 2>/dev/null || true

python3 -c "
import statistics as s
before = [float(x) for x in open('$BEFORE_LOG')]
after = [float(x) for x in open('$AFTER_LOG')]
def stats(name, xs):
    xs_sorted = sorted(xs)
    n = len(xs_sorted)
    p50 = xs_sorted[n//2]
    p95 = xs_sorted[int(n*0.95)] if n>1 else xs_sorted[0]
    print(f'{name}: n={n} avg={s.mean(xs):.4f}s stdev={s.pstdev(xs):.4f}s min={min(xs):.4f}s p50={p50:.4f}s p95={p95:.4f}s max={max(xs):.4f}s')
stats('BEFORE (3 cold connections)', before)
stats('AFTER  (ControlMaster 재사용)', after)
b_avg = s.mean(before); a_avg = s.mean(after)
print(f'delta avg: {(b_avg-a_avg):.4f}s ({(b_avg-a_avg)/b_avg*100:.1f}% reduction)')
"
