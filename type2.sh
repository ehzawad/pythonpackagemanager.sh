#!/usr/bin/env zsh
# =============================================================================
# Python Environment Manager - Single File Version
# Drop this entire block into your ~/.zshrc
# =============================================================================

() {
    # -------------------------------------------------------------------------
    # CONFIGURATION - Edit these variables to customize behavior
    # -------------------------------------------------------------------------
    
    # Feature toggles
    local -A CONFIG=(
        [BLOCK_PYTHON]=true          # Block 'python' outside venv
        [BLOCK_PYTHON3]=true         # Block 'python3' outside venv
        [BLOCK_PIP]=true             # Block 'pip' outside venv
        [ALLOW_VERSIONED]=true       # Allow python3.12, python3.11, etc outside venv
        [MIN_VERSION]="3.9"          # Minimum Python version to allow
        [MAX_VERSION]="3.13"         # Maximum Python version to allow
        [CACHE_SCAN]=true            # Cache Python scan results
        [CACHE_DURATION]=300         # Cache duration in seconds
        [OVERRIDE_PERSISTS]=false    # Persist setpy across shells
    )
    
    # Python search paths (in priority order - first match wins)
    local -a SEARCH_PATHS=(
        "$HOME/.local/bin"
        "$HOME/bin"
        "$HOME/.pythons/*/bin"
        "/opt/homebrew/bin"
        "/opt/homebrew/opt/python@*/bin"
        "/usr/local/bin"
        "/usr/local/opt/python@*/bin"
        "/usr/bin"
    )
    
    # Blocked paths (never use these specific Python installations)
    local -a BLOCKED_PATHS=(
        # Add paths to block, e.g.:
        # "/usr/bin/python3"
        # "/usr/local/bin/python3.8"
    )
    
    # Whitelist mode (if set, ONLY these paths allowed - overrides search)
    local -a ALLOWED_PATHS=(
        # Leave empty for normal mode, or specify exact paths:
        # "$HOME/.local/bin/python3.12"
        # "/opt/homebrew/bin/python3.12"
    )
    
    # Virtual environment indicators
    local -a VENV_INDICATORS=(
        VIRTUAL_ENV
        CONDA_DEFAULT_ENV
        POETRY_ACTIVE
        PIPENV_ACTIVE
    )
    
    # -------------------------------------------------------------------------
    # GLOBAL STATE (do not edit)
    # -------------------------------------------------------------------------
    
    typeset -gA _PYM_PYTHONS         # version -> path
    typeset -gA _PYM_INFO            # version -> info string
    typeset -g _PYM_SCANNED=0
    typeset -g _PYM_SCAN_TIME=0
    typeset -g _PYM_OVERRIDE=""
    typeset -g _PYM_OVERRIDE_FILE="$HOME/.pymanager_override"
    
    # -------------------------------------------------------------------------
    # HELPER FUNCTIONS
    # -------------------------------------------------------------------------
    
    _pym_in_venv() {
        for indicator in "${VENV_INDICATORS[@]}"; do
            [[ -n "${(P)indicator}" ]] && return 0
        done
        return 1
    }
    
    _pym_get_venv_version() {
        if [[ -n "$VIRTUAL_ENV" ]]; then
            if [[ -f "$VIRTUAL_ENV/pyvenv.cfg" ]]; then
                local ver=$(grep -E "^version\s*=" "$VIRTUAL_ENV/pyvenv.cfg" 2>/dev/null | \
                           sed -E 's/^version\s*=\s*([0-9]+\.[0-9]+).*/\1/')
                [[ -n "$ver" ]] && echo "$ver" && return 0
            fi
            if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
                "$VIRTUAL_ENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null
                return 0
            fi
        fi
        if [[ -n "$CONDA_DEFAULT_ENV" ]] && command -v python >/dev/null 2>&1; then
            python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null
            return 0
        fi
        return 1
    }
    
    _pym_is_blocked() {
        local path="$1"
        local realpath=$(readlink -f "$path" 2>/dev/null || echo "$path")
        for blocked in "${BLOCKED_PATHS[@]}"; do
            local blocked_real=$(readlink -f "$blocked" 2>/dev/null || echo "$blocked")
            [[ "$realpath" == "$blocked_real" ]] && return 0
        done
        return 1
    }
    
    _pym_version_ok() {
        local ver="$1"
        [[ "$ver" < "${CONFIG[MIN_VERSION]}" ]] && return 1
        [[ "$ver" > "${CONFIG[MAX_VERSION]}" ]] && return 1
        return 0
    }
    
    _pym_scan() {
        # Check cache
        if [[ "${CONFIG[CACHE_SCAN]}" == "true" ]] && [[ $_PYM_SCANNED -eq 1 ]]; then
            local now=$(date +%s)
            local age=$((now - _PYM_SCAN_TIME))
            [[ $age -lt ${CONFIG[CACHE_DURATION]} ]] && return 0
        fi
        
        _PYM_PYTHONS=()
        _PYM_INFO=()
        
        local -a found_pythons=()
        
        # Whitelist mode
        if (( ${#ALLOWED_PATHS} > 0 )); then
            for py in "${ALLOWED_PATHS[@]}"; do
                [[ -x "$py" ]] && found_pythons+=("$py")
            done
        else
            # Search mode
            for pattern in "${SEARCH_PATHS[@]}"; do
                for dir in ${~pattern}(N/); do
                    [[ -d "$dir" ]] || continue
                    for py in "$dir"/python*(N); do
                        [[ -x "$py" ]] || continue
                        [[ "$py" =~ "python-config" ]] && continue
                        [[ "$py" =~ "pythonw" ]] && continue
                        _pym_is_blocked "$py" && continue
                        found_pythons+=("$py")
                    done
                done
            done
        fi
        
        # Process each Python
        for py in $found_pythons; do
            local version=""
            local fullver=""
            
            if fullver=$("$py" --version 2>&1); then
                if [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)' ]]; then
                    version="${match[1]}.${match[2]}"
                    [[ "${match[1]}" == "2" ]] && continue
                    _pym_version_ok "$version" || continue
                fi
            else
                continue
            fi
            
            local realpath=$(readlink -f "$py" 2>/dev/null || echo "$py")
            
            # Store (prefer $HOME paths)
            if [[ -z "${_PYM_PYTHONS[$version]}" ]] || [[ "$py" == "$HOME"* ]]; then
                _PYM_PYTHONS[$version]="$py"
                _PYM_INFO[$version]="$fullver (-> $realpath)"
            fi
        done
        
        _PYM_SCANNED=1
        _PYM_SCAN_TIME=$(date +%s)
    }
    
    _pym_load_override() {
        if [[ "${CONFIG[OVERRIDE_PERSISTS]}" == "true" ]] && [[ -f "$_PYM_OVERRIDE_FILE" ]]; then
            _PYM_OVERRIDE=$(cat "$_PYM_OVERRIDE_FILE" 2>/dev/null)
        fi
    }
    
    _pym_save_override() {
        if [[ "${CONFIG[OVERRIDE_PERSISTS]}" == "true" ]]; then
            if [[ -n "$_PYM_OVERRIDE" ]]; then
                echo "$_PYM_OVERRIDE" > "$_PYM_OVERRIDE_FILE"
            else
                rm -f "$_PYM_OVERRIDE_FILE" 2>/dev/null
            fi
        fi
    }
    
    _pym_get_python_path() {
        local version="$1"
        
        # Priority 1: venv
        if _pym_in_venv; then
            if [[ -n "$version" ]] && [[ -x "$VIRTUAL_ENV/bin/python${version}" ]]; then
                echo "$VIRTUAL_ENV/bin/python${version}"
                return 0
            elif [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
                echo "$VIRTUAL_ENV/bin/python"
                return 0
            fi
            return 1
        fi
        
        # Priority 2: override (for generic commands)
        if [[ -z "$version" ]] && [[ -n "$_PYM_OVERRIDE" ]]; then
            _pym_scan
            [[ -n "${_PYM_PYTHONS[$_PYM_OVERRIDE]}" ]] && echo "${_PYM_PYTHONS[$_PYM_OVERRIDE]}" && return 0
        fi
        
        # Priority 3: specific version
        if [[ -n "$version" ]]; then
            _pym_scan
            [[ -n "${_PYM_PYTHONS[$version]}" ]] && echo "${_PYM_PYTHONS[$version]}" && return 0
        fi
        
        return 1
    }
    
    _pym_is_pip_module() {
        [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]
    }
    
    _pym_show_python_help() {
        local cmd="$1"
        echo "Error: No default '$cmd' command available"
        echo ""
        _pym_scan
        if (( ${#_PYM_PYTHONS} == 0 )); then
            echo "No Python 3.x installations found"
            return 1
        fi
        echo "Available Python versions:"
        local versions=(${(nO)${(k)_PYM_PYTHONS}})
        for ver in $versions; do
            echo "  python${ver} -> ${_PYM_INFO[$ver]}"
        done
        echo ""
        echo "Quick setup:"
        echo "  1. Create venv: python${versions[1]} -m venv .venv"
        echo "  2. Activate:    source .venv/bin/activate"
        echo ""
        echo "Or set default: setpy ${versions[1]}"
    }
    
    _pym_show_pip_blocked() {
        local cmd="$1"
        echo "Error: $cmd is blocked outside virtual environments"
        echo ""
        echo "To use pip:"
        echo "  1. Create venv: python3.x -m venv .venv"
        echo "  2. Activate:    source .venv/bin/activate"
        echo "  3. Use pip:     pip install <package>"
        echo ""
        echo "This prevents system-wide package pollution"
        [[ -n "$_PYM_OVERRIDE" ]] && echo "Note: Python override does NOT affect pip"
    }
    
    # -------------------------------------------------------------------------
    # PUBLIC FUNCTIONS - Command Wrappers
    # -------------------------------------------------------------------------
    
    python() {
        local py_path=$(_pym_get_python_path "")
        
        if [[ -n "$py_path" ]]; then
            if [[ "${CONFIG[BLOCK_PIP]}" == "true" ]] && _pym_is_pip_module "$@"; then
                if ! _pym_in_venv; then
                    _pym_show_pip_blocked "python -m pip"
                    return 1
                fi
            fi
            "$py_path" "$@"
            return $?
        fi
        
        if [[ "${CONFIG[BLOCK_PYTHON]}" == "true" ]]; then
            _pym_show_python_help "python"
            return 1
        else
            command python "$@"
            return $?
        fi
    }
    
    python3() {
        local py_path=$(_pym_get_python_path "")
        
        if [[ -n "$py_path" ]]; then
            if [[ "${CONFIG[BLOCK_PIP]}" == "true" ]] && _pym_is_pip_module "$@"; then
                if ! _pym_in_venv; then
                    _pym_show_pip_blocked "python3 -m pip"
                    return 1
                fi
            fi
            "$py_path" "$@"
            return $?
        fi
        
        if [[ "${CONFIG[BLOCK_PYTHON3]}" == "true" ]]; then
            _pym_show_python_help "python3"
            return 1
        else
            command python3 "$@"
            return $?
        fi
    }
    
    _pym_python_version_cmd() {
        local version="$1"
        shift
        
        # In venv: check compatibility
        if _pym_in_venv; then
            local venv_ver=$(_pym_get_venv_version)
            if [[ -x "$VIRTUAL_ENV/bin/python${version}" ]]; then
                "$VIRTUAL_ENV/bin/python${version}" "$@"
                return $?
            elif [[ "$version" == "$venv_ver" ]]; then
                "$VIRTUAL_ENV/bin/python" "$@"
                return $?
            else
                echo "Error: python${version} not available in this venv (uses Python ${venv_ver})"
                echo "Deactivate first with: deactivate"
                return 1
            fi
        fi
        
        # Outside venv
        if [[ "${CONFIG[ALLOW_VERSIONED]}" != "true" ]]; then
            echo "Error: Version-specific Python blocked outside venv"
            echo "Use 'python' with setpy, or activate a venv"
            return 1
        fi
        
        if [[ "${CONFIG[BLOCK_PIP]}" == "true" ]] && _pym_is_pip_module "$@"; then
            _pym_show_pip_blocked "python${version} -m pip"
            return 1
        fi
        
        local py_path=$(_pym_get_python_path "$version")
        if [[ -n "$py_path" ]]; then
            "$py_path" "$@"
            return $?
        else
            echo "Error: python${version} not found"
            return 1
        fi
    }
    
    pip() {
        if _pym_in_venv; then
            [[ -x "$VIRTUAL_ENV/bin/pip" ]] && "$VIRTUAL_ENV/bin/pip" "$@" && return $?
            command pip "$@"
            return $?
        fi
        if [[ "${CONFIG[BLOCK_PIP]}" == "true" ]]; then
            _pym_show_pip_blocked "pip"
            return 1
        else
            command pip "$@"
            return $?
        fi
    }
    
    pip3() {
        if _pym_in_venv; then
            [[ -x "$VIRTUAL_ENV/bin/pip3" ]] && "$VIRTUAL_ENV/bin/pip3" "$@" && return $?
            command pip3 "$@"
            return $?
        fi
        if [[ "${CONFIG[BLOCK_PIP]}" == "true" ]]; then
            _pym_show_pip_blocked "pip3"
            return 1
        else
            command pip3 "$@"
            return $?
        fi
    }
    
    _pym_pip_version_cmd() {
        local version="$1"
        shift
        if _pym_in_venv; then
            [[ -x "$VIRTUAL_ENV/bin/pip${version}" ]] && "$VIRTUAL_ENV/bin/pip${version}" "$@" && return $?
            local venv_ver=$(_pym_get_venv_version)
            [[ "$version" == "$venv_ver" ]] && "$VIRTUAL_ENV/bin/pip" "$@" && return $?
        fi
        if [[ "${CONFIG[BLOCK_PIP]}" == "true" ]]; then
            _pym_show_pip_blocked "pip${version}"
            return 1
        else
            command pip${version} "$@"
            return $?
        fi
    }
    
    # -------------------------------------------------------------------------
    # PUBLIC FUNCTIONS - User Commands
    # -------------------------------------------------------------------------
    
    setpy() {
        local version="$1"
        
        if [[ -z "$version" ]] || [[ "$version" == "clear" ]] || [[ "$version" == "reset" ]]; then
            if [[ -n "$_PYM_OVERRIDE" ]]; then
                local old="$_PYM_OVERRIDE"
                _PYM_OVERRIDE=""
                _pym_save_override
                echo "Cleared Python override (was ${old})"
            else
                echo "No Python override is set"
            fi
            return 0
        fi
        
        _pym_scan
        if [[ -z "${_PYM_PYTHONS[$version]}" ]]; then
            echo "Error: Python ${version} not found"
            echo "Available versions: ${(k)_PYM_PYTHONS}"
            return 1
        fi
        
        _PYM_OVERRIDE="$version"
        _pym_save_override
        echo "Set Python override to ${version}"
        echo "Now 'python' and 'python3' use python${version}"
        [[ "${CONFIG[BLOCK_PIP]}" == "true" ]] && echo "Note: pip remains blocked outside venvs"
        echo "To clear: setpy clear"
        
        _pym_in_venv && echo "Warning: In venv (takes precedence over override)"
    }
    
    pyinfo() {
        echo "Python Environment Status"
        echo "========================="
        echo ""
        
        # Override
        if [[ -n "$_PYM_OVERRIDE" ]]; then
            echo "Active Override: ${_PYM_OVERRIDE}"
            echo "  python/python3 -> python${_PYM_OVERRIDE}"
            echo "  Persistent: ${CONFIG[OVERRIDE_PERSISTS]}"
            echo ""
        fi
        
        # Venv
        if _pym_in_venv; then
            echo "Virtual Environment: ACTIVE"
            local venv_ver=$(_pym_get_venv_version)
            if [[ -n "$VIRTUAL_ENV" ]]; then
                echo "  Type: venv/virtualenv"
                echo "  Path: $VIRTUAL_ENV"
                echo "  Version: ${venv_ver:-unknown}"
            elif [[ -n "$CONDA_DEFAULT_ENV" ]]; then
                echo "  Type: conda"
                echo "  Name: $CONDA_DEFAULT_ENV"
                echo "  Version: ${venv_ver:-unknown}"
            fi
            echo ""
        else
            echo "Virtual Environment: INACTIVE"
            echo ""
        fi
        
        # Config
        echo "Configuration:"
        echo "  Block python:     ${CONFIG[BLOCK_PYTHON]}"
        echo "  Block python3:    ${CONFIG[BLOCK_PYTHON3]}"
        echo "  Block pip:        ${CONFIG[BLOCK_PIP]}"
        echo "  Allow versioned:  ${CONFIG[ALLOW_VERSIONED]}"
        echo "  Version range:    ${CONFIG[MIN_VERSION]} - ${CONFIG[MAX_VERSION]}"
        echo ""
        
        # System Pythons
        _pym_scan
        if (( ${#_PYM_PYTHONS} == 0 )); then
            echo "No Python installations found"
        else
            echo "System Python Installations:"
            local versions=(${(nO)${(k)_PYM_PYTHONS}})
            for ver in $versions; do
                local marker=""
                [[ "$ver" == "$_PYM_OVERRIDE" ]] && marker=" [OVERRIDE]"
                echo "  Python ${ver}${marker}"
                echo "    ${_PYM_PYTHONS[$ver]}"
                echo "    ${_PYM_INFO[$ver]}"
            done
        fi
    }
    
    pyscan() {
        echo "Scanning for Python installations..."
        _PYM_SCANNED=0
        _pym_scan
        if (( ${#_PYM_PYTHONS} == 0 )); then
            echo "No Python installations found"
            return 1
        fi
        echo "Found ${#_PYM_PYTHONS} Python version(s):"
        local versions=(${(nO)${(k)_PYM_PYTHONS}})
        for ver in $versions; do
            echo "  Python ${ver}: ${_PYM_PYTHONS[$ver]}"
        done
    }
    
    pyvenv() {
        local name="${1:-.venv}"
        local version="$2"
        local py_cmd=""
        
        if [[ -n "$version" ]]; then
            py_cmd="python${version}"
        elif [[ -n "$_PYM_OVERRIDE" ]]; then
            py_cmd="python${_PYM_OVERRIDE}"
        else
            _pym_scan
            local versions=(${(nO)${(k)_PYM_PYTHONS}})
            (( ${#versions} > 0 )) && py_cmd="python${versions[1]}" || { echo "Error: No Python found"; return 1; }
        fi
        
        echo "Creating venv '$name' with $py_cmd..."
        if $py_cmd -m venv "$name"; then
            echo "Success! Virtual environment created"
            echo "To activate: source $name/bin/activate"
        else
            echo "Error: Failed to create venv"
            return 1
        fi
    }
    
    pyhelp() {
        cat <<'EOF'
Python Manager - Help
=====================

COMMANDS:
  setpy <version>     Set temporary Python default
  setpy clear         Clear override
  pyinfo              Show environment status
  pyscan              Rescan for Pythons
  pyvenv [name] [ver] Create venv
  pyhelp              Show this help

USAGE:
  # Create and activate venv
  python3.12 -m venv .venv
  source .venv/bin/activate

  # Set temporary default
  setpy 3.12
  python --version

  # Quick venv
  pyvenv myproject 3.11
  source myproject/bin/activate

CONFIGURATION:
  Edit the CONFIG hash at the top of this script in ~/.zshrc

ENVIRONMENT VARIABLES (temporary overrides):
  PYMANAGER_BLOCK_PYTHON=false     Allow 'python' outside venv
  PYMANAGER_BLOCK_PIP=false        Allow 'pip' outside venv
EOF
    }
    
    # -------------------------------------------------------------------------
    # INITIALIZATION
    # -------------------------------------------------------------------------
    
    # Load persistent override if enabled
    _pym_load_override
    
    # Create version-specific functions (3.9-3.13)
    local min_minor=${CONFIG[MIN_VERSION]##*.}
    local max_minor=${CONFIG[MAX_VERSION]##*.}
    for minor in {$min_minor..$max_minor}; do
        local ver="3.${minor}"
        eval "python${ver}() { _pym_python_version_cmd '${ver}' \"\$@\"; }"
        eval "py${ver}() { _pym_python_version_cmd '${ver}' \"\$@\"; }"
        eval "pip${ver}() { _pym_pip_version_cmd '${ver}' \"\$@\"; }"
    done
    
} # End of IIFE

# Optional: Show load message (comment out if you don't want it)
# echo "Python Manager loaded (type 'pyhelp' for info)"
