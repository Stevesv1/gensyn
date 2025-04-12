#!/bin/bash

# Color codes for echo messages
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
NC='\033[0m' # No Color

# Function to print colorful messages
print_message() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}====== $1 ======${NC}"
}

# Step 1: Check if we're in rl-swarm directory
print_header "CHECKING RL-SWARM DIRECTORY"

if [[ $(basename "$PWD") == "rl-swarm" ]]; then
    print_success "Currently in rl-swarm directory."
    RL_SWARM_DIR="$PWD"
else
    print_warning "Not in rl-swarm directory. Checking HOME directory..."
    
    # Step 2: Check if rl-swarm directory exists in HOME
    if [[ -d "$HOME/rl-swarm" ]]; then
        print_success "Found rl-swarm directory in HOME."
        RL_SWARM_DIR="$HOME/rl-swarm"
    else
        print_error "rl-swarm directory not found in current directory or HOME."
        exit 1
    fi
fi

# Step 3: Navigate to rl-swarm directory
print_message "Navigating to $RL_SWARM_DIR"
cd "$RL_SWARM_DIR"
print_success "Successfully navigated to rl-swarm directory."

# Step 4: Check for cloudflared installation
print_header "CHECKING CLOUDFLARED"

# Detect architecture
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        CLOUDFLARED_ARCH="amd64"
        ;;
    aarch64|arm64)
        CLOUDFLARED_ARCH="arm64"
        ;;
    *)
        print_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

if command -v cloudflared &> /dev/null; then
    print_success "cloudflared is already installed."
else
    print_message "Installing cloudflared for $ARCH architecture..."
    
    # Create temporary directory for download
    mkdir -p /tmp/cloudflared-install
    cd /tmp/cloudflared-install
    
    # Download and install cloudflared based on the OS and architecture
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux installation
        curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}.deb" -o cloudflared.deb
        sudo dpkg -i cloudflared.deb || sudo apt-get install -f -y
        
        # If dpkg/apt fails, try direct binary installation
        if ! command -v cloudflared &> /dev/null; then
            curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}" -o cloudflared
            chmod +x cloudflared
            sudo mv cloudflared /usr/local/bin/
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS installation
        if command -v brew &> /dev/null; then
            brew install cloudflared
        else
            curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CLOUDFLARED_ARCH}.tgz" -o cloudflared.tgz
            tar -xzf cloudflared.tgz
            chmod +x cloudflared
            sudo mv cloudflared /usr/local/bin/
        fi
    else
        print_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
    
    # Navigate back to rl-swarm directory
    cd "$RL_SWARM_DIR"
    
    # Verify installation
    if command -v cloudflared &> /dev/null; then
        print_success "cloudflared installation completed successfully."
    else
        print_error "Failed to install cloudflared. Please install it manually."
        exit 1
    fi
fi

# Step 5: Check for python3 installation
print_header "CHECKING PYTHON3"

if command -v python3 &> /dev/null; then
    print_success "python3 is already installed."
else
    print_message "Installing python3..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-pip
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            brew install python
        else
            print_error "Homebrew not found. Please install python3 manually."
            exit 1
        fi
    else
        print_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
    
    if command -v python3 &> /dev/null; then
        print_success "python3 installation completed successfully."
    else
        print_error "Failed to install python3. Please install it manually."
        exit 1
    fi
fi

# Step 6: Run HTTP server on port 8000 or next available port
print_header "STARTING HTTP SERVER"

PORT=8000
MAX_RETRIES=10
RETRY_COUNT=0
SERVER_STARTED=false

# Function to check if port is in use
is_port_in_use() {
    if command -v nc &> /dev/null; then
        nc -z localhost "$1" &> /dev/null
        return $?
    elif command -v lsof &> /dev/null; then
        lsof -i:"$1" &> /dev/null
        return $?
    else
        # Fallback method using a temporary socket
        (echo > /dev/tcp/127.0.0.1/"$1") &> /dev/null
        return $?
    fi
}

# Function to start the HTTP server
start_http_server() {
    local port="$1"
    local temp_log="/tmp/http_server_$$.log"
    
    # Use python's built-in HTTP server
    python3 -m http.server "$port" > "$temp_log" 2>&1 &
    local pid=$!
    
    # Wait a moment to see if the server starts
    sleep 2
    
    # Check if the process is still running and didn't exit with an error
    if ps -p $pid > /dev/null; then
        print_success "HTTP server started successfully on port $port."
        echo "$pid" # Return the PID
    else
        # Check the log for errors
        if grep -q "Address already in use" "$temp_log"; then
            print_warning "Port $port is already in use."
            return 1
        else
            print_error "Failed to start HTTP server on port $port. Error log:"
            cat "$temp_log"
            return 1
        fi
    fi
}

while [[ $RETRY_COUNT -lt $MAX_RETRIES && $SERVER_STARTED == false ]]; do
    print_message "Attempting to start HTTP server on port $PORT..."
    
    # Check if the port is in use before trying to start the server
    if is_port_in_use "$PORT"; then
        print_warning "Port $PORT is already in use. Trying next port."
        PORT=$((PORT + 1))
        RETRY_COUNT=$((RETRY_COUNT + 1))
        continue
    fi
    
    # Try to start the HTTP server
    HTTP_SERVER_PID=$(start_http_server "$PORT")
    
    if [[ -n "$HTTP_SERVER_PID" ]]; then
        # Start cloudflared tunnel in the background
        print_message "Starting cloudflared tunnel to http://localhost:$PORT..."
        
        # Start the tunnel and capture its output
        cloudflared tunnel --url "http://localhost:$PORT" > /tmp/cloudflared_$$.log 2>&1 &
        CLOUDFLARED_PID=$!
        
        # Wait a moment for the tunnel to establish
        sleep 5
        
        # Extract the tunnel URL from the log file
        TUNNEL_URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' /tmp/cloudflared_$$.log | head -n 1)
        
        if [[ -n "$TUNNEL_URL" ]]; then
            print_success "Cloudflare tunnel established at: $TUNNEL_URL"
            
            # Step 7: Show download instructions
            print_header "DOWNLOAD INSTRUCTIONS"
            echo -e "${GREEN}Download your swarm.pem file using this command:${NC}"
            echo -e "wget -O swarm.pem ${TUNNEL_URL}/swarm.pem"
            echo
            echo -e "${GREEN}Similar for these 2 files as well:${NC}"
            echo -e "wget -O userData.json ${TUNNEL_URL}/modal-login/temp-data/userData.json"
            echo -e "wget -O userApiKey.json ${TUNNEL_URL}/modal-login/temp-data/userApiKey.json"
            
            SERVER_STARTED=true
        else
            print_warning "Cloudflared tunnel not established yet. Waiting longer..."
            
            # Wait a bit longer and try again
            sleep 10
            TUNNEL_URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' /tmp/cloudflared_$$.log | head -n 1)
            
            if [[ -n "$TUNNEL_URL" ]]; then
                print_success "Cloudflare tunnel established at: $TUNNEL_URL"
                
                # Step 7: Show download instructions
                print_header "DOWNLOAD INSTRUCTIONS"
                echo -e "${GREEN}Download your swarm.pem file using this command:${NC}"
                echo -e "wget -O swarm.pem ${TUNNEL_URL}/swarm.pem"
                echo
                echo -e "${GREEN}Similar for these 2 files as well:${NC}"
                echo -e "wget -O userData.json ${TUNNEL_URL}/modal-login/temp-data/userData.json"
                echo -e "wget -O userApiKey.json ${TUNNEL_URL}/modal-login/temp-data/userApiKey.json"
                
                SERVER_STARTED=true
            else
                print_error "Failed to establish cloudflared tunnel. Stopping services and trying another port."
                
                # Cleanup
                kill $HTTP_SERVER_PID 2>/dev/null
                kill $CLOUDFLARED_PID 2>/dev/null
                
                PORT=$((PORT + 1))
                RETRY_COUNT=$((RETRY_COUNT + 1))
            fi
        fi
    else
        # HTTP server failed to start, try the next port
        PORT=$((PORT + 1))
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi
done

if [[ $SERVER_STARTED == false ]]; then
    print_error "Failed to start HTTP server after $MAX_RETRIES attempts."
    exit 1
fi

print_header "SETUP COMPLETE"
print_success "Server running at http://localhost:$PORT"
print_success "Press Ctrl+C to stop the server when you're done."

# Wait for Ctrl+C
trap "echo -e '${YELLOW}Stopping servers...${NC}'; kill $HTTP_SERVER_PID 2>/dev/null; kill $CLOUDFLARED_PID 2>/dev/null; echo -e '${GREEN}Servers stopped.${NC}'" INT
wait
