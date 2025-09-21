from pathlib import Path
import subprocess
import os
import time

# Global variables for persistent System Console connection
system_console_process = None
system_console_initialized = False

def find_system_console():
    """Find system-console executable in C:\altera_pro\25.1.1\syscon\bin"""
    # Use only the specific Altera Pro 25.1.1 installation path
    system_console_path = r"C:\altera_pro\25.1.1\syscon\bin\system-console.exe"
    
    try:
        # Check if file exists
        if Path(system_console_path).exists():
            return system_console_path
    except:
        pass
    
    return None

# Global variables for persistent System Console connection
system_console_process = None
system_console_initialized = False


def initialize_system_console():
    """Initialize System Console once with one_ai.tcl"""
    global system_console_process, system_console_initialized
    
    system_console = find_system_console()
    if not system_console:
        ##print("Error: system-console not found!")
        return False
    
    try:
        #print(f"Initializing System Console at: {system_console}")
        #print("Loading one_ai.tcl (one-time setup)...")
        
        # Start System Console in interactive mode (hidden)
        system_console_process = subprocess.Popen(
            [system_console, "-cli"],  # Use command line interface
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=os.path.dirname(os.path.abspath(__file__)),
            bufsize=1,  # Line buffered
            universal_newlines=True,
            creationflags=subprocess.CREATE_NO_WINDOW  # Hide window on Windows
        )
        
        # Wait a bit for System Console to start
        time.sleep(2)
        
        # Send one_ai.tcl source command
        system_console_process.stdin.write("source one_ai.tcl\n")
        system_console_process.stdin.flush()
        
        # Wait for initialization to complete
        time.sleep(3)
        
        # Check if process is still running
        if system_console_process.poll() is None:
            system_console_initialized = True
            ##print("System Console initialized successfully!")
            return True
        else:
            #print("System Console failed to start")
            return False
            
    except Exception as e:
        #print(f"Error initializing System Console: {e}")
        return False
        
def execute_paint():
    """Execute only paint command in the existing System Console"""
    global system_console_process, system_console_initialized
    
    if not system_console_initialized or system_console_process is None:
        #print("System Console not initialized, attempting to initialize...")
        if not initialize_system_console():
            return False
    
    try:
        # Check if process is still alive
        if system_console_process.poll() is not None:
            #print("System Console process died, reinitializing...")
            system_console_initialized = False
            if not initialize_system_console():
                return False
        
        # Send paint command
        #print("Sending paint command...")
        start_time = time.time()
        system_console_process.stdin.write("paint\n")
        system_console_process.stdin.flush()
        
        # Give it time to execute
        time.sleep(0.1)  # Increased from 1.0 to 1.2 seconds
        
        # Try to send a simple command to test if System Console is responsive
        try:
            system_console_process.stdin.write("puts \"TCL_ALIVE\"\n")
            system_console_process.stdin.flush()
            time.sleep(0.2)
        except Exception as e:
            #print(f"Warning: Could not send test command: {e}")
            return False
        
        # Try to read any available output (non-blocking)
        try:
            # Check if there's any output available
            import select
            if hasattr(select, 'select'):  # Unix-like systems
                ready, _, _ = select.select([system_console_process.stdout], [], [], 0)
                if ready:
                    output = system_console_process.stdout.read(1024)
                    #print(f"System Console output: {output}")
        except:
            pass  # Windows doesn't support select on pipes
        
        return True
        
    except Exception as e:
        #print(f"Error executing paint: {e}")
        # Try to reinitialize on error
        system_console_initialized = False
        return False

def cleanup_system_console():
    """Clean up System Console process"""
    global system_console_process, system_console_initialized
    
    if system_console_process is not None:
        try:
            system_console_process.stdin.write("exit\n")
            system_console_process.stdin.flush()
            system_console_process.wait(timeout=5)
        except:
            system_console_process.terminate()
            try:
                system_console_process.wait(timeout=5)
            except:
                system_console_process.kill()
        
        system_console_process = None
        system_console_initialized = False
        
def execute_camera():
    """Execute only camera command in the existing System Console"""
    global system_console_process, system_console_initialized
    
    if not system_console_initialized or system_console_process is None:
        #print("System Console not initialized, attempting to initialize...")
        if not initialize_system_console():
            return False
    
    try:
        # Check if process is still alive
        if system_console_process.poll() is not None:
            #print("System Console process died, reinitializing...")
            system_console_initialized = False
            if not initialize_system_console():
                return False
        
        
        # Send camera command
        #print("Sending camera command...")
        start_time = time.time()
        system_console_process.stdin.write("camera\n")
        system_console_process.stdin.flush()
        
        # Give it time to execute
        time.sleep(0.1)  # Increased from 1.0 to 1.2 seconds
        
        # Try to send a simple command to test if System Console is responsive
        try:
            system_console_process.stdin.write("puts \"TCL_ALIVE\"\n")
            system_console_process.stdin.flush()
            time.sleep(0.2)
        except Exception as e:
            #print(f"Warning: Could not send test command: {e}")
            return False
        
        # Try to read any available output (non-blocking)
        try:
            # Check if there's any output available
            import select
            if hasattr(select, 'select'):  # Unix-like systems
                ready, _, _ = select.select([system_console_process.stdout], [], [], 0)
                if ready:
                    output = system_console_process.stdout.read(1024)
                    #print(f"System Console output: {output}")
        except:
            pass  # Windows doesn't support select on pipes
        
        return True
        
    except Exception as e:
        #print(f"Error executing camera: {e}")
        # Try to reinitialize on error
        system_console_initialized = False
        return False

def cleanup_system_console():
    """Clean up System Console process"""
    global system_console_process, system_console_initialized
    
    if system_console_process is not None:
        try:
            system_console_process.stdin.write("exit\n")
            system_console_process.stdin.flush()
            system_console_process.wait(timeout=5)
        except:
            system_console_process.terminate()
            try:
                system_console_process.wait(timeout=5)
            except:
                system_console_process.kill()
        
        system_console_process = None
        system_console_initialized = False    

def check_system_status():
    """Check if the TCL script and FPGA connection are working"""
    global system_console_process, system_console_initialized
    
    if not system_console_initialized or system_console_process is None:
        return False
    
    try:
        # Send a simple test command to check if System Console responds
        system_console_process.stdin.write("puts \"STATUS_CHECK\"\n")
        system_console_process.stdin.flush()
        time.sleep(0.5)
        
        # Try to send a JTAG chain query to check FPGA connection
        system_console_process.stdin.write("get_service_paths device\n")
        system_console_process.stdin.flush()
        time.sleep(0.5)
        
        return True
    except Exception as e:
        #print(f"System status check failed: {e}")
        return False

def force_system_console_restart():
    """Force a complete restart of System Console and TCL script loading"""
    global system_console_process, system_console_initialized
    
    #print("=== FORCING COMPLETE SYSTEM CONSOLE RESTART ===")
    
    # Kill existing process
    cleanup_system_console()
    
    # Wait a bit longer for complete cleanup
    time.sleep(3)
    
    # Reinitialize everything
    if initialize_system_console():
        #print("Complete restart successful!")
        return True
    else:
        #print("Complete restart failed!")
        return False        