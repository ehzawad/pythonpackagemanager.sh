
# Function to get the list of installed Python versions
get_python_versions() {
    local python_dirs
    python_dirs=$(find "$HOME/.python"* -maxdepth 0 -type d 2>/dev/null)
    python_versions=()
    for dir in $python_dirs; do
        version=$(basename "$dir" | sed 's/\.python//')
        python_versions+=("$version")
    done
}

# Get the list of installed Python versions
get_python_versions

# Set the PATH to include the bin directories of installed Python versions
for version in "${python_versions[@]}"; do
    export PATH="$HOME/.python$version/bin:$PATH"
done

# Check if pip is installed for each Python version and set the aliases accordingly
for version in "${python_versions[@]}"; do
    if [[ -f "$HOME/.python$version/bin/pip" ]]; then
        alias pip$version="$HOME/.python$version/bin/pip"
    else
        alias pip$version='echo "Please install pip'"$version"' in $HOME/.python'"$version"'/bin/"'
    fi
done

# Function to check if running in a virtual environment or conda environment
is_virtual_env() {
    if [[ -n "$VIRTUAL_ENV" || -n "$CONDA_DEFAULT_ENV" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to enforce a specific Python version and its associated pip
enforce_python() {
    if is_virtual_env; then
        # In a virtual environment or conda environment, use the original commands
        command "$@"
    else
        # Check if the command is python, python3, pip, or pip3
        if [[ "$1" == "python" || "$1" == "python3" ]]; then
            echo "Please specify the desired Python version. Available versions: ${python_versions[*]}"
        elif [[ "$1" == "pip" || "$1" == "pip3" ]]; then
            echo "Please create a virtual environment and then run pip. It is recommended."
        else
            command "$@"
        fi
    fi
}

# Function to print the absolute path of the Python executable
print_python_path() {
    if is_virtual_env; then
        echo "Python environment: $(which python)"
    else
        echo "Python environment: $HOME/.python$version/bin/python$version"
    fi
}

# Alias python, python3, pip, and pip3 to the enforce_python function
alias python='enforce_python python'
alias python3='enforce_python python3'
alias pip='enforce_python pip'
alias pip3='enforce_python pip3'

# Function to handle python* command for each version
for version in "${python_versions[@]}"; do
    eval "python$version() {
        if is_virtual_env; then
            # In a virtual environment, use the Python executable from the environment
            \"\$(which python)\" \"\$@\"
        else
            # Outside a virtual environment, use the default Python \$version
            $HOME/.python$version/bin/python$version \"\$@\"
        fi
    }"
done

# Print the Python path when activating a virtual environment
activate() {
    source "$@"
    print_python_path
}
