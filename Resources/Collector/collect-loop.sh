export LC_ALL=C
export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/local/nvidia/bin"
prev=""
cpu_lines() {
  cur=$(grep '^cpu ' /proc/stat 2>/dev/null)
  net0=""
  if [ -z "$prev" ]; then
    echo "$cur"; net0=$(net_line); sleep 0.3; cur=$(grep '^cpu ' /proc/stat 2>/dev/null)
  else
    echo "$prev"
  fi
  echo "$cur"
  prev=$cur
}
net_line() {
  awk -v u="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" 'NR>2 {gsub(":"," "); if ($1 ~ /^(lo|docker|veth|br-|virbr|cni|flannel|cali|tunl|vxlan|kube)/) next; rx+=$2; tx+=$10} END {printf "%s %.0f %.0f\n", u, rx, tx}' /proc/net/dev 2>/dev/null
}
snap() {
echo "@@HOST"; hostname 2>/dev/null
echo "@@OS"; ( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" ) || uname -sr
echo "@@UPTIME"; cut -d' ' -f1 /proc/uptime 2>/dev/null
echo "@@NCPU"; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null
echo "@@LOAD"; cat /proc/loadavg 2>/dev/null
echo "@@CPU"; cpu_lines
echo "@@MEM"; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
echo "@@DISK"; df -kP / 2>/dev/null | tail -n 1
# Total bytes received / sent on physical-ish interfaces, with a timestamp.
echo "@@NET"; [ -n "$net0" ] && echo "$net0"; net_line
pids=""
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "@@GPU"
  nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>&1
  apps=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
  echo "@@APPS"; echo "$apps"
  pids=$(echo "$apps" | awk -F', *' 'NF>=2 && $2 ~ /^[0-9]+$/ {print $2}' | sort -u | tr '\n' ',' | sed 's/,$//')
  ps_out=""; if [ -n "$pids" ]; then ps_out=$(ps -o pid=,user=,etimes=,pcpu=,rss=,args= -p "$pids" 2>/dev/null | cut -c1-600); fi
  echo "@@PS"; echo "$ps_out"
  # Container: nvidia-smi reports host PIDs we can't see; use the heuristic.
  [ -z "$ps_out" ] && pids=""
else
  echo "@@NOGPU"
fi
# Sample both rankings on every server, including hosts with GPU workloads.
top=$(ps -eo pid=,user=,etimes=,pcpu=,rss=,args= --sort=-pcpu 2>/dev/null | head -n 20 | cut -c1-600)
topmem=$(ps -eo pid=,user=,etimes=,pcpu=,rss=,args= --sort=-rss 2>/dev/null | head -n 20 | cut -c1-600)
echo "@@TOP"; echo "$top"
echo "@@TOPMEM"; echo "$topmem"
echo "@@CWD"
for p in $(echo "$pids" | tr ',' ' ') $(printf '%s\n%s\n' "$top" "$topmem" | awk '{print $1}'); do
  d=$(readlink "/proc/$p/cwd" 2>/dev/null) && echo "$p $d"
done
echo "@@END"
}
while read -r _; do snap </dev/null; done
