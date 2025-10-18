
# Python Version Manager by ehzawad@gmail.com
# Global variables
typeset -ga _PYTHON_VERSIONS
typeset -gA _PYTHON_PATHS
typeset -gA _PYTHON_INFO
typeset -g _VENV_PYTHON_VERSION_CACHE=""
typeset -g _LAST_VIRTUAL_ENV=""
typeset -g _PYTHONS_SCANNED=0
typeset -g _PYTHON_OVERRIDE=""

# Comprehensive Python scanner - lazy loaded
_scan_all_pythons() {
    # Skip if already scanned
    [[ $_PYTHONS_SCANNED -eq 1 ]] && return 0
    
    _PYTHON_VERSIONS=()
    _PYTHON_PATHS=()
    _PYTHON_INFO=()
    
    # All possible Python locations on macOS
    local search_paths=(
        # User installations (preferred)
        "$HOME/.local/bin"
        "$HOME/bin"
        "$HOME/.pythons/*/bin"
        "$HOME/Library/Python/*/bin"
        
        # Homebrew
        "/opt/homebrew/bin"
        "/opt/homebrew/opt/python@*/bin"
        "/usr/local/bin"
        "/usr/local/opt/python@*/bin"
        
        # System Python
        "/usr/bin"
        
        # Custom installations
        "/opt/python*/bin"
        "$HOME/opt/python*/bin"
        "$HOME/opt/python/*/bin"      # For structure like ~/opt/python/3.12.12/bin
        "/opt/python/*/bin"            # For structure like /opt/python/3.12.12/bin
    )
    
    # First pass: find all python executables
    local python_executables=()
    
    for pattern in "${search_paths[@]}"; do
        for dir in ${~pattern}(N/); do
            [[ -d "$dir" ]] || continue
            
            # Find ALL python executables
            for py in "$dir"/python*(N); do
                [[ -x "$py" ]] || continue
                [[ "$py" =~ "python-config" ]] && continue
                [[ "$py" =~ "pythonw" ]] && continue
                
                python_executables+=("$py")
            done
        done
    done
    
    # Second pass: get version info for each executable
    for py in $python_executables; do
        # Try to get version
        local version=""
        local fullver=""
        
        # Method 1: Extract from filename
        if [[ "${py:t}" =~ '^python([0-9]+\.?[0-9]*)$' ]]; then
            version="${match[1]}"
        fi
        
        # Method 2: Run the executable to get version (with validation)
        if fullver=$("$py" --version 2>&1); then
            # Validate it's actually Python
            if [[ ! "$fullver" =~ ^Python ]]; then
                continue  # Not a Python interpreter
            fi
            if [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.?[0-9]*' ]]; then
                local extracted_version="${match[1]}.${match[2]}"
                
                if [[ -z "$version" ]]; then
                    version="$extracted_version"
                fi
                
                # Skip Python 2
                if [[ "${match[1]}" == "2" ]]; then
                    continue
                fi
            fi
        else
            continue
        fi
        
        # If we still don't have a version, try one more method
        if [[ -z "$version" ]] || [[ "$version" == "3" ]]; then
            local pyver=$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
            if [[ -n "$pyver" ]] && [[ "$pyver" =~ '^3\.' ]]; then
                version="$pyver"
            fi
        fi
        
        # Skip if we couldn't determine version or if it's Python 2
        [[ -z "$version" ]] && continue
        [[ "$version" =~ '^2' ]] && continue
        
        # Get real path if it's a symlink (macOS-compatible)
        local realpath="$py"
        if [[ -L "$py" ]]; then
            local count=0
            while [[ -L "$realpath" ]] && (( count++ < 50 )); do
                local target=$(readlink "$realpath" 2>/dev/null || echo "$realpath")
                # Handle relative symlinks
                [[ "$target" != /* ]] && target="${realpath:h}/$target"
                realpath="$target"
            done
        fi
        
        # Determine if we should store this Python
        local should_store=0
        
        if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
            # First time seeing this major.minor version
            should_store=1
        else
            # Already have this version, decide which to keep
            
            # Preference 1: Always prefer $HOME/.local/bin
            if [[ "${py%/*}" == "$HOME/.local/bin" ]]; then
                should_store=1
            # Preference 2: Compare patch versions - keep the highest
            elif [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.([0-9]+)' ]]; then
                local new_major="${match[1]}"
                local new_minor="${match[2]}"
                local new_patch="${match[3]}"
                
                # Extract stored version
                local stored_info="${_PYTHON_INFO[$version]}"
                if [[ "$stored_info" =~ 'Python ([0-9]+)\.([0-9]+)\.([0-9]+)' ]]; then
                    local stored_major="${match[1]}"
                    local stored_minor="${match[2]}"
                    local stored_patch="${match[3]}"
                    
                    # Compare patch versions numerically
                    if (( new_patch > stored_patch )); then
                        should_store=1
                    fi
                fi
            fi
        fi
        
        # Store this Python if we decided to
        if [[ $should_store -eq 1 ]]; then
            # Only add to array if this is the first time we see this major.minor
            if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
                _PYTHON_VERSIONS+=("$version")
            fi
            _PYTHON_PATHS[$version]="$py"
            _PYTHON_INFO[$version]="$fullver ($realpath)"
        fi
    done
    
    # Sort versions numerically in ascending order (3.9, 3.10, 3.11...)
    _PYTHON_VERSIONS=(${(nu)_PYTHON_VERSIONS})
    _PYTHONS_SCANNED=1
}

# Check if we're in a virtual environment
_in_virtual_env() {
    [[ -n "$VIRTUAL_ENV" ]] && return 0
    [[ -n "$CONDA_DEFAULT_ENV" ]] && return 0
    [[ -n "$POETRY_ACTIVE" ]] && return 0
    [[ -n "$PIPENV_ACTIVE" ]] && return 0
    return 1
}

# Get the Python version used by current venv - with caching
_get_venv_python_version() {
    # Check cache first
    if [[ -n "$VIRTUAL_ENV" ]] && [[ "$VIRTUAL_ENV" == "$_LAST_VIRTUAL_ENV" ]] && [[ -n "$_VENV_PYTHON_VERSION_CACHE" ]]; then
        echo "$_VENV_PYTHON_VERSION_CACHE"
        return 0
    fi
    
    local ver=""
    
    if [[ -n "$VIRTUAL_ENV" ]]; then
        # Method 1: Check pyvenv.cfg (fastest)
        if [[ -f "$VIRTUAL_ENV/pyvenv.cfg" ]]; then
            # Extract only major.minor version (3.12) not full version (3.12.11)
            local full_version=$(grep -E "^version\s*=" "$VIRTUAL_ENV/pyvenv.cfg" 2>/dev/null | sed -E 's/^version\s*=\s*(.*)$/\1/' | tr -d ' ')
            if [[ "$full_version" =~ ^([0-9]+\.[0-9]+) ]]; then
                ver="${match[1]}"
            fi
        fi
        
        # Method 2: Run the venv's python (slower but reliable)
        if [[ -z "$ver" ]] && [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
            ver=$("$VIRTUAL_ENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        fi
        
        # Cache the result
        if [[ -n "$ver" ]]; then
            _LAST_VIRTUAL_ENV="$VIRTUAL_ENV"
            _VENV_PYTHON_VERSION_CACHE="$ver"
            echo "$ver"
            return 0
        fi
    fi
    
    # For conda
    if [[ -n "$CONDA_DEFAULT_ENV" ]] && command -v python >/dev/null 2>&1; then
        ver=$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return 0
        fi
    fi
    
    return 1
}

# Python wrapper
python() {
    # Priority 1: Virtual environment
    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
            "$VIRTUAL_ENV/bin/python" "$@"
        else
            command python "$@"
        fi
        return $?
    fi
    
    # Priority 2: Temporary override
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Check if trying to use pip module
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            echo "❌ python -m pip is blocked outside virtual environments"
            echo ""
            echo "💡 To use pip:"
            echo "   1. Create a virtual environment: python${_PYTHON_OVERRIDE} -m venv [venv-projname]"
            echo "   2. Activate it: source [venv-projname]/bin/activate"
            echo "   3. Then use pip normally"
            echo ""
            echo "🛡️  This prevents accidental system-wide package installations"
            echo "ℹ️  Note: Temporary Python override does NOT affect pip"
            return 1
        fi
        
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Priority 3: System fallback (if explicitly allowed AND override is set)
    if [[ -n "$PYTHON_ALLOW_SYSTEM" ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Still block pip even with system fallback
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            echo "❌ python -m pip is blocked outside virtual environments"
            echo ""
            echo "💡 To use pip:"
            echo "   1. Create a virtual environment and activate it"
            echo "   2. Then use pip normally"
            echo ""
            echo "🛡️  This prevents accidental system-wide package installations"
            echo "ℹ️  Note: PYTHON_ALLOW_SYSTEM does NOT affect pip"
            return 1
        fi
        
        # Use the setpy override for build tools
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Default: Show error
    _scan_all_pythons
    
    echo "❌ No default 'python' command available"
    echo ""
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "⚠️  No Python 3.x installations found!"
        return 1
    fi
    
    echo "🐍 Available Python versions:"
    echo ""
    
    local sorted_versions=(${(nO)_PYTHON_VERSIONS})
    for ver in $sorted_versions; do
        echo "  • python${ver} → ${_PYTHON_INFO[$ver]}"
    done
    
    echo ""
    echo "💡 Options:"
    echo "   1. Create venv: python${_PYTHON_VERSIONS[-1]} -m venv [venv-projname] && source [venv-projname]/bin/activate"
    echo "   2. Set temporary default: setpy ${_PYTHON_VERSIONS[-1]}"
    echo "   3. For build tools: setpy <version> && PYTHON_ALLOW_SYSTEM=1 your-build-command"
    
    return 1
}

# Python3 wrapper
python3() {
    # Priority 1: Virtual environment
    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/python3" ]]; then
            "$VIRTUAL_ENV/bin/python3" "$@"
        else
            command python3 "$@"
        fi
        return $?
    fi
    
    # Priority 2: Temporary override
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Check if trying to use pip module
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            echo "❌ python3 -m pip is blocked outside virtual environments"
            echo ""
            echo "💡 To use pip:"
            echo "   1. Create a virtual environment: python${_PYTHON_OVERRIDE} -m venv [venv-projname]"
            echo "   2. Activate it: source [venv-projname]/bin/activate"
            echo "   3. Then use pip normally"
            echo ""
            echo "🛡️  This prevents accidental system-wide package installations"
            echo "ℹ️  Note: Temporary Python override does NOT affect pip"
            return 1
        fi
        
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Priority 3: System fallback (if explicitly allowed AND override is set)
    if [[ -n "$PYTHON_ALLOW_SYSTEM" ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Still block pip even with system fallback
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            echo "❌ python3 -m pip is blocked outside virtual environments"
            echo ""
            echo "💡 To use pip:"
            echo "   1. Create a virtual environment and activate it"
            echo "   2. Then use pip normally"
            echo ""
            echo "🛡️  This prevents accidental system-wide package installations"
            echo "ℹ️  Note: PYTHON_ALLOW_SYSTEM does NOT affect pip"
            return 1
        fi
        
        # Use the setpy override for build tools
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Default: Show error
    _scan_all_pythons
    
    echo "❌ No default 'python3' command available"
    echo ""
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "⚠️  No Python 3.x installations found!"
        return 1
    fi
    
    echo "🐍 Available Python versions:"
    echo ""
    
    local sorted_versions=(${(nO)_PYTHON_VERSIONS})
    for ver in $sorted_versions; do
        echo "  • python${ver} → ${_PYTHON_INFO[$ver]}"
    done
    
    echo ""
    echo "💡 Options:"
    echo "   1. Create venv: python${_PYTHON_VERSIONS[-1]} -m venv [venv-projname] && source [venv-projname]/bin/activate"
    echo "   2. Set temporary default: setpy ${_PYTHON_VERSIONS[-1]}"
    echo "   3. For build tools: setpy <version> && PYTHON_ALLOW_SYSTEM=1 your-build-command"
    
    return 1
}

# Pip wrapper - NEVER allows override
pip() {
    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
            "$VIRTUAL_ENV/bin/pip" "$@"
        else
            command pip "$@"
        fi
        return $?
    fi
    
    echo "❌ pip is not available outside virtual environments"
    echo ""
    echo "💡 To use pip:"
    echo "   1. Create a virtual environment: python3.x -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "🛡️  This prevents accidental system-wide package installations"
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "ℹ️  Note: Temporary Python override does NOT affect pip"
    fi
    
    return 1
}

# Pip3 wrapper - NEVER allows override
pip3() {
    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/pip3" ]]; then
            "$VIRTUAL_ENV/bin/pip3" "$@"
        else
            command pip3 "$@"
        fi
        return $?
    fi
    
    pip "$@"
}

# Set temporary Python default
setpy() {
    local version="$1"
    
    # Handle clear/reset
    if [[ -z "$version" ]] || [[ "$version" == "clear" ]] || [[ "$version" == "reset" ]]; then
        if [[ -n "$_PYTHON_OVERRIDE" ]]; then
            echo "✅ Cleared Python override (was ${_PYTHON_OVERRIDE})"
            _PYTHON_OVERRIDE=""
        else
            echo "ℹ️  No Python override was set"
        fi
        return 0
    fi
    
    # Strip "python" prefix if provided (accept both "3.12" and "python3.12")
    if [[ "$version" =~ ^python([0-9]+\.?[0-9]*)$ ]]; then
        version="${match[1]}"
    elif [[ "$version" =~ ^py([0-9]+\.?[0-9]*)$ ]]; then
        version="${match[1]}"
    fi
    
    # Ensure pythons are scanned
    _scan_all_pythons
    
    # Validate version exists
    if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
        echo "❌ Python ${version} not found on this system"
        echo ""
        echo "Available versions:"
        for ver in $_PYTHON_VERSIONS; do
            echo "  • ${ver}"
        done
        return 1
    fi
    
    # Set override
    _PYTHON_OVERRIDE="$version"
    echo "✅ Set temporary Python default to ${version}"
    echo ""
    echo "ℹ️  Now 'python' and 'python3' will use Python ${version}"
    echo "⚠️  This does NOT affect pip - pip remains blocked outside venvs"
    echo ""
    echo "💡 To clear: setpy clear"
    
    # Show a warning if in venv
    if _in_virtual_env; then
        echo ""
        echo "⚠️  Note: You're in a virtual environment, which takes precedence"
    fi
}

# Python version-specific wrapper function
_python_version_wrapper() {
    local version="$1"
    shift
    
    # If in venv, be more permissive
    if _in_virtual_env; then
        # First, check if the requested python executable exists in the venv
        if [[ -x "$VIRTUAL_ENV/bin/python${version}" ]]; then
            # It exists! Just use it directly
            "$VIRTUAL_ENV/bin/python${version}" "$@"
            return $?
        fi
        
        # If not found, check if this matches the venv's major.minor version
        local venv_version=$(_get_venv_python_version)
        
        # Extract just major.minor from the full version if needed
        if [[ "$venv_version" =~ ^([0-9]+\.[0-9]+) ]]; then
            venv_version="${match[1]}"
        fi
        
        if [[ "$version" == "$venv_version" ]]; then
            # Fall back to the venv's python
            if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
                "$VIRTUAL_ENV/bin/python" "$@"
                return $?
            fi
        else
            # Only block if it truly doesn't exist and isn't the venv's version
            echo "❌ python${version} is not available in this virtual environment"
            echo ""
            echo "🌟 This virtual environment uses Python ${venv_version}"
            echo "   Available: python, python3, python${venv_version}"
            echo ""
            echo "💡 To use a different Python version, deactivate first with: deactivate"
            return 1
        fi
    fi
    
    # Outside venv: ensure we have scanned for pythons
    _scan_all_pythons
    
    # Check if trying to use pip module
    if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
        echo "❌ python${version} -m pip is blocked outside virtual environments"
        echo ""
        echo "💡 To use pip:"
        echo "   1. Create a virtual environment: python${version} -m venv [venv-projname]"
        echo "   2. Activate it: source [venv-projname]/bin/activate"
        echo "   3. Then use pip normally"
        echo ""
        echo "🛡️  This prevents accidental system-wide package installations"
        return 1
    fi
    
    # Check if this version exists
    if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
        echo "❌ python${version} not found on this system"
        return 1
    fi
    
    # Allow all other python usage
    "${_PYTHON_PATHS[$version]}" "$@"
}

# Pip version-specific wrapper
_pip_version_wrapper() {
    local version="$1"
    shift
    
    # If in venv, be more permissive
    if _in_virtual_env; then
        # First check if the requested pip executable exists in the venv
        if [[ -x "$VIRTUAL_ENV/bin/pip${version}" ]]; then
            # It exists! Just use it directly
            "$VIRTUAL_ENV/bin/pip${version}" "$@"
            return $?
        fi
        
        # If not found, check if this matches the venv's major.minor version
        local venv_version=$(_get_venv_python_version)
        
        # Extract just major.minor from the full version if needed
        if [[ "$venv_version" =~ ^([0-9]+\.[0-9]+) ]]; then
            venv_version="${match[1]}"
        fi
        
        if [[ "$version" == "$venv_version" ]]; then
            # Fall back to the venv's pip
            if [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
                "$VIRTUAL_ENV/bin/pip" "$@"
                return $?
            fi
        else
            echo "❌ pip${version} is not available in this virtual environment"
            echo ""
            echo "🌟 This virtual environment uses Python ${venv_version}"
            echo "   Available: pip, pip3, pip${venv_version}"
            echo ""
            echo "💡 To use a different Python version, deactivate first with: deactivate"
            return 1
        fi
    fi
    
    # Outside venv: always block (even with override)
    echo "❌ pip${version} is not available outside virtual environments"
    echo ""
    echo "💡 To use pip:"
    echo "   1. Create a virtual environment: python${version} -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "🛡️  This prevents accidental system-wide package installations"
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "ℹ️  Note: Temporary Python override does NOT affect pip"
    fi
    return 1
}

# Create version functions for a wide range (covers current and future Python versions)
# Note: The wrapper functions handle non-existent versions gracefully with helpful error messages
# This range (3.8-3.25) should cover Python releases for many years to come
for major in 3; do
    for minor in {8..25}; do
        local ver="${major}.${minor}"
        # Validate version format to prevent code injection via eval
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
            eval "python${ver}() { _python_version_wrapper '${ver}' \"\$@\"; }"
            eval "py${ver}() { _python_version_wrapper '${ver}' \"\$@\"; }"
            eval "pip${ver}() { _pip_version_wrapper '${ver}' \"\$@\"; }"
        fi
    done
done

# Enhanced pyinfo function
pyinfo() {
    echo "🔍 Python Environment Status:"
    echo ""
    
    # Show override if set
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo "⚡ Temporary Python Override Active: ${_PYTHON_OVERRIDE}"
        echo "   'python' and 'python3' → python${_PYTHON_OVERRIDE}"
        echo "   (use 'setpy clear' to remove)"
        echo ""
    fi
    
    # Check virtual environment status
    if _in_virtual_env; then
        echo "✅ Virtual Environment Active!"
        echo ""
        
        local venv_version=$(_get_venv_python_version)
        
        if [[ -n "$VIRTUAL_ENV" ]]; then
            echo "  Type: venv/virtualenv"
            echo "  Path: $VIRTUAL_ENV"
            echo "  Python version: ${venv_version:-unknown}"
        elif [[ -n "$CONDA_DEFAULT_ENV" ]]; then
            echo "  Type: conda"
            echo "  Name: $CONDA_DEFAULT_ENV"
            echo "  Python version: ${venv_version:-unknown}"
        elif [[ -n "$POETRY_ACTIVE" ]]; then
            echo "  Type: poetry"
        elif [[ -n "$PIPENV_ACTIVE" ]]; then
            echo "  Type: pipenv"
        fi
        
        echo ""
        echo "  Available commands in this venv:"
        echo "    python     → $(command -v python 2>/dev/null || echo 'not found')"
        echo "    python3    → $(command -v python3 2>/dev/null || echo 'not found')"
        if [[ -n "$venv_version" ]]; then
            echo "    python${venv_version} → $(command -v python${venv_version} 2>/dev/null || echo 'accessible')"
        fi
        echo "    pip        → $(command -v pip 2>/dev/null || echo 'not found')"
        echo "    pip3       → $(command -v pip3 2>/dev/null || echo 'not found')"
        if [[ -n "$venv_version" ]]; then
            echo "    pip${venv_version}    → $(command -v pip${venv_version} 2>/dev/null || echo 'accessible')"
        fi
        echo ""
        echo "  ⚠️  Other Python versions are blocked while venv is active"
        echo ""
        echo "────────────────────────────────"
        echo ""
    else
        echo "❌ No Virtual Environment Active"
        echo ""
    fi
    
    _scan_all_pythons
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "No Python 3.x found on system"
    else
        echo "📦 System Python Versions:"
        for ver in $_PYTHON_VERSIONS; do
            echo ""
            echo "  Python $ver:"
            echo "    Path: ${_PYTHON_PATHS[$ver]}"
            echo "    Info: ${_PYTHON_INFO[$ver]}"
            echo "    Usage: python${ver} -m venv <venv-name>"
            if [[ "$ver" == "$_PYTHON_OVERRIDE" ]]; then
                echo "    Status: ⚡ Currently set as override"
            fi
        done
        echo ""
        echo "⚠️  pip is blocked for all system Python versions"
        echo "💡 Always use virtual environments for package management"
    fi
}
# Custom which wrapper to handle our Python functions
which() {
    local cmd="$1"
    
    # Handle our Python-related functions
    case "$cmd" in
        python|python3|python[0-9].[0-9]|python[0-9].[0-9][0-9]|py[0-9].[0-9]|py[0-9].[0-9][0-9])
            if _in_virtual_env; then
                if [[ -x "$VIRTUAL_ENV/bin/$cmd" ]]; then
                    echo "$VIRTUAL_ENV/bin/$cmd"
                    return 0
                fi
            else
                # Outside venv
                # Check for override first for python/python3
                if [[ -n "$_PYTHON_OVERRIDE" ]]; then
                    if [[ "$cmd" == "python" ]] || [[ "$cmd" == "python3" ]]; then
                        _scan_all_pythons
                        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                            echo "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
                            return 0
                        fi
                    fi
                fi
                
                # Check for specific version commands
                if [[ "$cmd" =~ ^python([0-9]+\.?[0-9]*)$ ]] || [[ "$cmd" =~ ^py([0-9]+\.?[0-9]*)$ ]]; then
                    local version="${match[1]}"
                    _scan_all_pythons
                    if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                        echo "${_PYTHON_PATHS[$version]}"
                        return 0
                    fi
                fi
            fi
            echo "which: no $cmd in PATH"
            return 1
            ;;
        pip|pip3|pip[0-9].[0-9]|pip[0-9].[0-9][0-9])
            if _in_virtual_env; then
                if [[ -x "$VIRTUAL_ENV/bin/$cmd" ]]; then
                    echo "$VIRTUAL_ENV/bin/$cmd"
                    return 0
                fi
            fi
            echo "which: no $cmd in PATH"
            return 1
            ;;
        *)
            # For all other commands, use the builtin which
            command which "$@"
            ;;
    esac
}
