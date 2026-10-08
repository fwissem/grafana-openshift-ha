#!/usr/bin/env bash
# check-prereqs.sh - report what is available for the local functional test.
#
# READ-ONLY: installs nothing, changes nothing. Run it inside WSL (Ubuntu) or any
# Linux shell on the test machine:
#
#   bash tests/local/check-prereqs.sh
#
# The report is printed and saved to tests/local/out/prereqs.txt (git-ignored).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"
REPORT="$OUT/prereqs.txt"

have() { command -v "$1" >/dev/null 2>&1; }

ver() {  # ver <tool> <args...> : first line of the version output, or "not installed"
  local tool="$1"; shift
  if have "$tool"; then
    "$tool" "$@" </dev/null 2>&1 | head -n 1
  else
    echo "not installed"
  fi
}

{
  echo "== System =="
  echo "date      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kernel    : $(uname -sr)"
  if [ -r /etc/os-release ]; then
    echo "os        : $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
  fi
  if grep -qi microsoft /proc/version 2>/dev/null; then echo "wsl       : yes"; else echo "wsl       : no"; fi
  echo "cpus      : $(nproc 2>/dev/null || echo unknown)"
  echo "memory    : $(awk '/MemTotal/ {printf "%.1f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null)"
  echo "disk free : $(df -h "$HERE" 2>/dev/null | awk 'NR==2 {print $4}')"
  echo "systemd   : $(ps -p 1 -o comm= 2>/dev/null)"
  echo
  echo "== Container engine =="
  echo "docker    : $(ver docker --version)"
  if have docker; then
    if docker info >/dev/null 2>&1; then echo "docker daemon : reachable"; else echo "docker daemon : NOT reachable"; fi
  fi
  echo "podman    : $(ver podman --version)"
  echo
  echo "== Kubernetes tooling =="
  echo "kind      : $(ver kind version)"
  echo "k3d       : $(ver k3d version)"
  echo "minikube  : $(ver minikube version --short)"
  echo "kubectl   : $(ver kubectl version --client)"
  echo "oc        : $(ver oc version --client)"
  echo "helm      : $(ver helm version --short)"
  echo "jq        : $(ver jq --version)"
  echo "git       : $(ver git --version)"
  echo "curl      : $(ver curl --version)"
  echo
  echo "== Network reachability (HTTP status; 000 = blocked) =="
  if have curl; then
    for url in \
      https://registry-1.docker.io/v2/ \
      https://get.helm.sh/ \
      https://grafana-community.github.io/helm-charts/index.yaml \
      https://kind.sigs.k8s.io/ \
      https://dl.k8s.io/release/stable.txt \
      https://github.com/ ; do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" </dev/null 2>/dev/null)"
      printf '%-62s %s\n' "$url" "${code:-000}"
    done
  else
    echo "curl not installed - skipped"
  fi
} 2>&1 | tee "$REPORT"

echo
echo "Report saved to: $REPORT"
