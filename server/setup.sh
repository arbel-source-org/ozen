#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
home_dir="${OZEN_HOME:-$HOME/ozen-server}"
cpu=0
[[ "${1:-}" == "--cpu" ]] && cpu=1

if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
    echo "Python's venv module is missing. On Ubuntu: sudo apt install python3-venv" >&2
    exit 1
fi

mkdir -p "$home_dir"
python3 -m venv "$home_dir/venv"
"$home_dir/venv/bin/pip" install --quiet --upgrade pip
"$home_dir/venv/bin/pip" install --quiet -r "$here/requirements.txt"
if [[ $cpu == 0 ]]; then
    "$home_dir/venv/bin/pip" install --quiet nvidia-cublas-cu12 'nvidia-cudnn-cu12==9.*'
fi
cp "$here/ozen_server.py" "$here/try_server.py" "$home_dir/"

code_file="$home_dir/pairing-code"
if [[ ! -s "$code_file" ]]; then
    (umask 077; "$home_dir/venv/bin/python" -c 'import secrets; print(secrets.token_urlsafe(12))' > "$code_file")
fi
chmod 600 "$code_file"

if [[ $cpu == 1 ]]; then
    defaults="--device cpu --compute-type int8"
else
    defaults=""
fi
cat > "$home_dir/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$home_dir"
if [[ $cpu == 0 ]]; then
    export LD_LIBRARY_PATH="\$(venv/bin/python -c 'import os, nvidia.cublas.lib, nvidia.cudnn.lib; print(os.path.dirname(nvidia.cublas.lib.__file__) + ":" + os.path.dirname(nvidia.cudnn.lib.__file__))'):\${LD_LIBRARY_PATH:-}"
fi
export OZEN_TOKEN="\$(cat pairing-code)"
exec venv/bin/python ozen_server.py $defaults "\$@"
EOF
chmod 700 "$home_dir/run.sh"

echo
echo "Set up in $home_dir"
echo "Start it:      $home_dir/run.sh"
echo "Pairing code:  $(cat "$code_file")"
echo "(the phone needs this code: Settings, Engine, Home computer)"
