# Shared color/log helpers -- `source` this, don't execute it directly.
# Kept minimal on purpose: just enough vocabulary (log/warn/die) that
# warnings and errors are visually distinct from routine output, no
# framework to learn per script.

readonly CCred=$(printf '\033[0;31m')
readonly CCyellow=$(printf '\033[0;33m')
readonly CCgreen=$(printf '\033[92m')
readonly CCblue=$(printf '\033[94m')
readonly CCcyan=$(printf '\033[36m')
readonly CCend=$(printf '\033[0m')
readonly CCbold=$(printf '\033[1m')
readonly CCunderline=$(printf '\033[4m')

echo_err()
{
    >&2 echo "$@"
}

log()
{
    echo_err "${CCblue}[${CCend}${CCgreen}*${CCend}${CCblue}]${CCend} $@"
}

warn()
{
    echo_err "${CCyellow}${CCbold}WARNING: $@${CCend}"
}

die()
{
    echo_err "${CCred}${CCbold}ERROR: $@${CCend}"
    exit 2
}
