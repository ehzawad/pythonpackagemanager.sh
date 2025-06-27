# Global variables
typeset -ga _PYTHON_VERSIONS
typeset -gA _PYTHON_PATHS
typeset -gA _PYTHON_INFO

# Comprehensive Python scanner
_scan_all_pythons() {
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
        
        # System Python (important!)
        "/usr/bin"
        
        # Custom installations
        "/opt/python*/bin"
        "$HOME/opt/python*/bin"
    )
    
    # First pass: find all python executables
    local python_executables=()
    
    for pattern in $search_paths; do
        for dir in ${~pattern}(N/); do
            [[ -d "$dir" ]] || continue
            
            # Find ALL python executables (python3, python3.x, python)
            for py in "$dir"/python*(N); do
                [[ -x "$py" ]] || continue
                [[ "$py" =~ "python-config" ]] && continue  # Skip config scripts
                [[ "$py" =~ "pythonw" ]] && continue       # Skip pythonw
                
                python_executables+=("$py")
            done
        done
    done
    
    # Second pass: get version info for each executable
    for py in $python_executables; do
        # Try to get version
        local version=""
        local fullver=""
        
        # Method 1: Extract from filename (e.g., python3.12)
        if [[ "${py:t}" =~ '^python([0-9]+\.?[0-9]*)$' ]]; then
            version="${match[1]}"
        fi
        
        # Method 2: Run the executable to get version
        if fullver=$("$py" --version 2>&1); then
            # Extract version from output like "Python 3.9.6"
            if [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.?[0-9]*' ]]; then
                local extracted_version="${match[1]}.${match[2]}"
                
                # If we didn't get version from filename, use extracted
                if [[ -z "$version" ]]; then
                    version="$extracted_version"
                fi
                
                # Skip if this is Python 2
                if [[ "${match[1]}" == "2" ]]; then
                    continue
                fi
            fi
        else
            # Couldn't run it, skip
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
        
        # Get real path if it's a symlink
        local realpath="$py"
        [[ -L "$py" ]] && realpath=$(readlink -f "$py" 2>/dev/null || readlink "$py" 2>/dev/null || echo "$py")
        
        # Store, preferring $HOME/.local/bin
        if [[ -z "${_PYTHON_PATHS[$version]}" ]] || [[ "${py%/*}" == "$HOME/.local/bin" ]]; then
            _PYTHON_VERSIONS+=("$version")
            _PYTHON_PATHS[$version]="$py"
            _PYTHON_INFO[$version]="$fullver ($realpath)"
        fi
    done
    
    # Sort versions numerically
    _PYTHON_VERSIONS=(${(nou)_PYTHON_VERSIONS})
}

# Check if we're in a virtual environment
_in_virtual_env() {
    # Check for venv/virtualenv
    [[ -n "$VIRTUAL_ENV" ]] && return 0
    
    # Check for conda
    [[ -n "$CONDA_DEFAULT_ENV" ]] && return 0
    
    # Check for poetry
    [[ -n "$POETRY_ACTIVE" ]] && return 0
    
    # Check for pipenv
    [[ -n "$PIPENV_ACTIVE" ]] && return 0
    
    return 1
}

# Python wrapper
python() {
    # If in virtual environment, use the venv's python
    if _in_virtual_env; then
        command python "$@"
        return $?
    fi
    
    # Otherwise, show our custom message
    _scan_all_pythons
    
    echo "❌ No default 'python' command available"
    echo ""
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "⚠️  No Python 3.x installations found!"
        echo ""
        echo "💡 Install Python to ~/.local/bin"
        return 1
    fi
    
    echo "🐍 Available Python versions on this system:"
    echo ""
    
    local sorted_versions=(${(nO)_PYTHON_VERSIONS})
    for ver in $sorted_versions; do
        echo "  • python${ver} → ${_PYTHON_INFO[$ver]}"
    done
    
    echo ""
    echo "💡 Use explicit version: python${sorted_versions[1]}, py${sorted_versions[1]}, etc."
    
    return 1
}

# Python3 wrapper
python3() {
    # If in virtual environment, use the venv's python3
    if _in_virtual_env; then
        command python3 "$@"
        return $?
    fi
    
    # Otherwise, show our custom message
    _scan_all_pythons
    
    echo "❌ No default 'python3' command available"
    echo ""
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "⚠️  No Python 3.x installations found!"
        echo ""
        echo "💡 Install Python to ~/.local/bin or use Homebrew"
        return 1
    fi
    
    echo "🐍 Available Python versions on this system:"
    echo ""
    
    local sorted_versions=(${(nO)_PYTHON_VERSIONS})
    for ver in $sorted_versions; do
        echo "  • python${ver} → ${_PYTHON_INFO[$ver]}"
    done
    
    echo ""
    echo "💡 Use explicit version: python${sorted_versions[1]}, py${sorted_versions[1]}, etc."
    
    return 1
}

# Pip wrapper
pip() {
    # If in virtual environment, use the venv's pip
    if _in_virtual_env; then
        command pip "$@"
        return $?
    fi
    
    # Otherwise, show our custom message
    _scan_all_pythons
    
    echo "❌ No default 'pip' command available"
    echo ""
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "⚠️  No Python installations found!"
        return 1
    fi
    
    echo "🐍 Available pip versions:"
    echo ""
    
    local sorted_versions=(${(nO)_PYTHON_VERSIONS})
    for ver in $sorted_versions; do
        echo "  • pip${ver} (via python${ver} -m pip)"
    done
    
    return 1
}

# Pip3 wrapper
pip3() {
    # If in virtual environment, use the venv's pip3
    if _in_virtual_env; then
        command pip3 "$@"
        return $?
    fi
    
    # Otherwise, delegate to pip function
    pip "$@"
}

# Initial scan and create aliases
_scan_all_pythons

# Create version-specific aliases
for ver in $_PYTHON_VERSIONS; do
    alias "python${ver}"="${_PYTHON_PATHS[$ver]}"
    alias "py${ver}"="${_PYTHON_PATHS[$ver]}"
    alias "pip${ver}"="${_PYTHON_PATHS[$ver]} -m pip"
done

# Debug function (optional - remove if not needed)
pyinfo() {
    echo "🔍 Python Discovery Debug Info:"
    echo ""
    
    # Check virtual environment status first
    if _in_virtual_env; then
        echo "🌟 Virtual Environment Active!"
        echo ""
        if [[ -n "$VIRTUAL_ENV" ]]; then
            echo "  Type: venv/virtualenv"
            echo "  Path: $VIRTUAL_ENV"
        elif [[ -n "$CONDA_DEFAULT_ENV" ]]; then
            echo "  Type: conda"
            echo "  Name: $CONDA_DEFAULT_ENV"
        elif [[ -n "$POETRY_ACTIVE" ]]; then
            echo "  Type: poetry"
        elif [[ -n "$PIPENV_ACTIVE" ]]; then
            echo "  Type: pipenv"
        fi
        echo ""
        echo "  python  → $(command -v python 2>/dev/null || echo 'not found')"
        echo "  python3 → $(command -v python3 2>/dev/null || echo 'not found')"
        echo "  pip     → $(command -v pip 2>/dev/null || echo 'not found')"
        echo "  pip3    → $(command -v pip3 2>/dev/null || echo 'not found')"
        echo ""
        echo "────────────────────────────────"
        echo ""
    fi
    
    _scan_all_pythons
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "No Python 3.x found. Checking what's available..."
        echo ""
        for dir in /usr/bin /usr/local/bin /opt/homebrew/bin ~/.local/bin; do
            if [[ -d "$dir" ]]; then
                echo "📁 $dir:"
                ls -la "$dir"/python* 2>/dev/null | grep -E '^[^d].*python' || echo "   (no python found)"
            fi
        done
    else
        echo "Found ${#_PYTHON_VERSIONS} Python version(s):"
        for ver in $_PYTHON_VERSIONS; do
            echo ""
            echo "Version $ver:"
            echo "  Path: ${_PYTHON_PATHS[$ver]}"
            echo "  Info: ${_PYTHON_INFO[$ver]}"
        done
    fi
}
