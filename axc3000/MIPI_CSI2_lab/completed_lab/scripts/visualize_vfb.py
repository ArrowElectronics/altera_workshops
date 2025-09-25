#!/usr/bin/env python3
"""
Python script to execute Quartus STP with one_ai.tcl and visualize the resulting RGB image.
The script runs 'quartus_stp -t one_ai.tcl' and then displays the vfb_content.rgb file
which contains RGB values for a 320x200 pixel image.
"""

import subprocess
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.widgets import RadioButtons
from pathlib import Path
import sys
import os
import time
import threading
from queue import Queue, Empty
import socket
import telnetlib3
import serial
import serial.tools.list_ports
import re

def find_system_console():
    """Find system-console executable in D:\altera_pro\25.1.1\syscon\bin"""
    # Use only the specific Altera Pro 25.1.1 installation path
    system_console_path = r"D:\altera_pro\25.1.1\syscon\bin\system-console.exe"
    
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
        print("Error: system-console not found!")
        return False
    
    try:
        print(f"Initializing System Console at: {system_console}")
        print("Loading one_ai.tcl (one-time setup)...")
        
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
            print("System Console initialized successfully!")
            return True
        else:
            print("System Console failed to start")
            return False
            
    except Exception as e:
        print(f"Error initializing System Console: {e}")
        return False

def execute_export_rgb():
    """Execute only exportRGB command in the existing System Console"""
    global system_console_process, system_console_initialized
    
    if not system_console_initialized or system_console_process is None:
        print("System Console not initialized, attempting to initialize...")
        if not initialize_system_console():
            return False
    
    try:
        # Check if process is still alive
        if system_console_process.poll() is not None:
            print("System Console process died, reinitializing...")
            system_console_initialized = False
            if not initialize_system_console():
                return False
        
        # Record RGB file timestamp before exportRGB
        rgb_file_path = Path("vfb_content.rgb")
        pre_export_mtime = rgb_file_path.stat().st_mtime if rgb_file_path.exists() else 0
        
        # Send exportRGB command
        #print("Sending exportRGB command...")
        start_time = time.time()
        system_console_process.stdin.write("exportRGB\n")
        system_console_process.stdin.flush()
        
        # Give it time to execute
        time.sleep(1.2)  # Increased from 1.0 to 1.2 seconds
        
        # Check if RGB file was actually updated
        if rgb_file_path.exists():
            post_export_mtime = rgb_file_path.stat().st_mtime
            if post_export_mtime <= pre_export_mtime:
                print(f"Warning: exportRGB did not update RGB file (pre: {pre_export_mtime}, post: {post_export_mtime})")
                # Don't return False immediately, but flag this for the caller
                execute_export_rgb.file_not_updated = True
            else:
                execute_export_rgb.file_not_updated = False
        
        # Try to send a simple command to test if System Console is responsive
        try:
            system_console_process.stdin.write("puts \"TCL_ALIVE\"\n")
            system_console_process.stdin.flush()
            time.sleep(0.2)
        except Exception as e:
            print(f"Warning: Could not send test command: {e}")
            return False
        
        # Try to read any available output (non-blocking)
        try:
            # Check if there's any output available
            import select
            if hasattr(select, 'select'):  # Unix-like systems
                ready, _, _ = select.select([system_console_process.stdout], [], [], 0)
                if ready:
                    output = system_console_process.stdout.read(1024)
                    print(f"System Console output: {output}")
        except:
            pass  # Windows doesn't support select on pipes
        
        return True
        
    except Exception as e:
        print(f"Error executing exportRGB: {e}")
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

def run_quartus_stp():
    """Execute exportRGB using persistent System Console connection"""
    return execute_export_rgb()

def load_rgb_image(filename="vfb_content.rgb", width=320, height=200):
    """Load RGB image from binary file"""
    try:
        # Check if file exists
        if not Path(filename).exists():
            print(f"Error: {filename} not found!")
            return None
        
        # Get file modification time to check if it's fresh
        file_stat = os.stat(filename)
        file_age = time.time() - file_stat.st_mtime
        # print(f"RGB file age: {file_age:.2f} seconds")
        
        # Store file modification time for external access
        load_rgb_image.last_file_mtime = file_stat.st_mtime
        
        # Warn if file is very old
        if file_age > 3.0:  # Reduced threshold from 5.0 to 3.0
            print(f"Warning: RGB file is {file_age:.1f} seconds old - may be stale")
        
        # Read binary RGB data
        with open(filename, 'rb') as f:
            rgb_data = f.read()
        
        #print(f"RGB file size: {len(rgb_data)} bytes")
        
        # Calculate expected file size
        expected_size = width * height * 3  # 3 bytes per pixel (RGB)
        
        if len(rgb_data) != expected_size:
            # Check if we have the common +2 bytes issue
            if len(rgb_data) == expected_size + 2:
                rgb_data = rgb_data[:-2]
            elif len(rgb_data) < expected_size:
                #print("File is smaller than expected. Padding with zeros...")
                rgb_data += b'\x00' * (expected_size - len(rgb_data))
            else:
                #print("File is larger than expected. Truncating...")
                rgb_data = rgb_data[:expected_size]
        
        # Convert to numpy array and reshape
        rgb_array = np.frombuffer(rgb_data, dtype=np.uint8)
        rgb_image = rgb_array.reshape((height, width, 3))

        return rgb_image 
        
    except Exception as e:
        print(f"Error loading RGB image: {e}")
        return None

def visualize_image(rgb_image, title="VFB Content (320x200)"):
    """Visualize the RGB image using matplotlib in fullscreen"""
    try:
        # Clear previous plot
        plt.clf()
        
        # Display full RGB image
        plt.imshow(rgb_image)
        plt.title(title, fontsize=16)
        plt.axis('off')
        
        # Make it fullscreen-like
        plt.tight_layout()
        plt.subplots_adjust(top=0.95, bottom=0.05, left=0.05, right=0.95)
        
        # Draw the updated plot
        plt.draw()
        plt.pause(0.01)  # Very brief pause to update display
        
        # Print image statistics
        print(f"Image shape: {rgb_image.shape}")
        print(f"Image dtype: {rgb_image.dtype}")
        print(f"Min values (R,G,B): {rgb_image.min(axis=(0,1)).tolist()}")
        print(f"Max values (R,G,B): {rgb_image.max(axis=(0,1)).tolist()}")
        print(f"Mean values (R,G,B): {rgb_image.mean(axis=(0,1)).round(2).tolist()}")
        
    except Exception as e:
        print(f"Error visualizing image: {e}")
        
def capture_thread(image_queue, stop_event):
    """Thread function for capturing images"""
    
    # Initialize System Console once at the beginning
    #print("Initializing System Console for the first time...")
    if not initialize_system_console():
        #print("Failed to initialize System Console!")
        return
    
    while not stop_event.is_set():
        try:
            #print(f"--- New capture attempt at {time.strftime('%H:%M:%S')} ---")
                         
            # Start timing for the entire capture cycle
            cycle_start_time = time.time()
            
            # Step 1: Execute only exportRGB (one_ai.tcl already loaded)
            fpga_connected = execute_export_rgb()
            
            if fpga_connected:
                time.sleep(0.01)
                #print("exportRGB executed successfully!")
                # Check if the file was actually updated
                #if hasattr(execute_export_rgb, 'file_not_updated') and execute_export_rgb.file_not_updated:
                    #print("But RGB file was not updated - possible FPGA connection issue")
                    # Continue anyway to try loading the existing file
            else:
                #print("Failed to execute exportRGB. Checking system status...")
                if not check_system_status():
                    #print("System status check failed. Attempting full restart...")
                    system_console_initialized = False
                    cleanup_system_console()
                    time.sleep(2)
                    continue
            
            # Step 2: Always try to load the RGB image from file
            #print("Loading RGB image from file...")
            rgb_image = load_rgb_image()
            
            if rgb_image is not None:
                # Successfully loaded image from file
                #print("RGB image loaded successfully!")
                current_time = time.strftime('%H:%M:%S')
                
                # Check if the RGB file has been updated since last exportRGB
                if hasattr(load_rgb_image, 'last_file_mtime'):
                    current_file_mtime = load_rgb_image.last_file_mtime
                    
                    # Track file modification time
                    if hasattr(capture_thread, 'last_file_mtime'):
                        if current_file_mtime == capture_thread.last_file_mtime:
                            # File hasn't been updated by exportRGB
                            if not hasattr(capture_thread, 'file_stale_since'):
                                capture_thread.file_stale_since = current_time_seconds
                            else:
                                stale_duration = current_time_seconds - capture_thread.file_stale_since
                                if stale_duration > 3.0:  # File not updated for more than 3 seconds
                                    print(f"RGB file not updated for {stale_duration:.1f}s despite exportRGB success - forcing restart...")
                                    system_console_initialized = False
                                    cleanup_system_console()
                                    time.sleep(1)
                                    continue
                        else:
                            # File was updated - reset stale timer
                            if hasattr(capture_thread, 'file_stale_since'):
                                delattr(capture_thread, 'file_stale_since')
                    
                    capture_thread.last_file_mtime = current_file_mtime
                
                # Check if image data has changed by computing a simple hash
                image_hash = hash(rgb_image.tobytes())
                current_time_seconds = time.time()
                
                if hasattr(capture_thread, 'last_image_hash'):
                    if image_hash == capture_thread.last_image_hash:
                        #print("Warning: Image data hasn't changed!")
                        # Track how long the image has been unchanged
                        if not hasattr(capture_thread, 'image_unchanged_since'):
                            capture_thread.image_unchanged_since = current_time_seconds
                        else:
                            unchanged_duration = current_time_seconds - capture_thread.image_unchanged_since
                            if unchanged_duration > 8.0:  # Reduced from 10.0 to 8.0 seconds
                                print(f"Image unchanged for {unchanged_duration:.1f}s - reinitializing System Console...")
                                
                                # Use more aggressive restart if this is a repeated failure
                                if not hasattr(capture_thread, 'restart_count'):
                                    capture_thread.restart_count = 0
                                
                                capture_thread.restart_count += 1
                                
                                if capture_thread.restart_count <= 2:
                                    # Try normal restart first
                                    system_console_initialized = False
                                    cleanup_system_console()
                                    if initialize_system_console():
                                        capture_thread.image_unchanged_since = current_time_seconds  # Reset timer
                                    #else:
                                        print("Failed to reinitialize System Console")
                                else:
                                    # Use complete restart after 2 failed attempts
                                    #print("Multiple restart attempts failed - trying complete restart...")
                                    if force_system_console_restart():
                                        capture_thread.restart_count = 0  # Reset counter on success
                                        capture_thread.image_unchanged_since = current_time_seconds
                                    else:
                                        #print("Complete restart failed - continuing with errors...")
                                        time.sleep(5)  # Wait longer before next attempt
                    else:
                        #print("Image data has changed - new frame detected")
                        # Reset the unchanged timer and restart counter
                        if hasattr(capture_thread, 'image_unchanged_since'):
                            delattr(capture_thread, 'image_unchanged_since')
                        if hasattr(capture_thread, 'restart_count'):
                            capture_thread.restart_count = 0  # Reset restart counter on success
                else:
                    time.sleep(.01)
                    #print("First frame detected")
                    
                capture_thread.last_image_hash = image_hash
                
                # Put new image in queue
                image_queue.put((rgb_image, f"VFB Content - {current_time}"))
                    
            else:
                # No RGB file found, create a black image
                #print("No RGB file found. Creating black image...")
                black_image = np.zeros((320, 200, 3), dtype=np.uint8)
                current_time = time.strftime('%H:%M:%S')
                image_queue.put((black_image, f"VFB Content - {current_time} (No RGB file)"))
            
            # Calculate elapsed time for this cycle
            cycle_time = time.time() - cycle_start_time
            
            # Dynamic delay based on FPGA connection status
            if fpga_connected:
                # FPGA connected: Target 1 FPS (1000ms per frame) since hardware seems slower
                target_frame_time = 1.0  # 1.0 seconds = 1000ms
                
                if cycle_time < target_frame_time:
                    # Need to wait to maintain 1 FPS
                    sleep_time = target_frame_time - cycle_time
                    #print(f"Cycle took {cycle_time*1000:.1f}ms, sleeping {sleep_time*1000:.1f}ms to maintain 1 FPS")
                    time.sleep(sleep_time)
                else:
                    # Cycle took longer than target, no sleep needed
                    actual_fps = 1.0 / cycle_time
                    #print(f"Cycle took {cycle_time*1000:.1f}ms (running at {actual_fps:.1f} FPS)")
            else:
                # FPGA not connected: Slower retry rate
                #print("Waiting 2 seconds before retry...")
                time.sleep(2)  # Reduced from 5 to 2 seconds
            
        except Exception as e:
            print(f"Error in capture thread: {e}")
            # On error, create a black image
            black_image = np.zeros((320, 200, 3), dtype=np.uint8)
            current_time = time.strftime('%H:%M:%S')
            image_queue.put((black_image, f"VFB Content - {current_time} (Error)"))
            time.sleep(2)
    
    # Cleanup when thread stops
    #print("Cleaning up System Console...")
    cleanup_system_console()

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
        print(f"System status check failed: {e}")
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

# Global variables for serial communication
serial_port = None
probabilities = [0] * 10  # Data 0-9 probabilities
serial_lock = threading.Lock()
serial_running = False

def list_com_ports():
    """List all available COM ports"""
    try:
        ports = serial.tools.list_ports.comports()
        available_ports = []
        
        #print("\n=== Available COM Ports ===")
        for i, port in enumerate(ports):
            print(f"{i+1}: {port.device} - {port.description}")
            available_ports.append(port.device)
        
        if not available_ports:
            #print("No COM ports found!")
            return None
        
        return available_ports
    except Exception as e:
        print(f"Error listing COM ports: {e}")
        return None

def select_com_port():
    """Let user select a COM port"""
    available_ports = list_com_ports()
    if not available_ports:
        return None
    
    while True:
        try:
            choice = input(f"\nSelect COM port (1-{len(available_ports)}): ")
            #choice = 1
            port_index = int(choice) - 1
            
            if 0 <= port_index < len(available_ports):
                selected_port = available_ports[port_index]
                print(f"Selected: {selected_port}")
                return selected_port
            else:
                print(f"Please enter a number between 1 and {len(available_ports)}")
        except ValueError:
            time.sleep(.01)
            #print("Please enter a valid number")

def initialize_serial_connection(port_name):
    """Initialize serial connection and wait for 'Done Initializing'"""
    global serial_port
    
    try:
        print(f"\nOpening {port_name} at 115200 baud...")
        serial_port = serial.Serial(port_name, 115200, timeout=1)
        time.sleep(2)  # Give time for connection to establish
        
        #print("Waiting for 'Done Initializing' message...")
        start_time = time.time()
        timeout = 30  # 30 second timeout
        
        while time.time() - start_time < timeout:
            if serial_port.in_waiting > 0:
                line = serial_port.readline().decode('utf-8', errors='ignore').strip()
                print(f"Received: {line}")
                
                if "Done Initializing" in line:
                    #print("✓ NIOS V initialization complete!")
                    return True
            
            time.sleep(0.1)
        
        #print("Timeout waiting for 'Done Initializing'")
        return False
        
    except Exception as e:
        print(f"Error initializing serial connection: {e}")
        return False

def parse_pixel_reader_response(response_text):
    """Parse the pixel reader response and extract Data 0-9"""
    global probabilities
    
    try:
        #print(f"[PARSE]: Starting to parse response...")
        #print(f"[PARSE]: Response length: {len(response_text)} characters")
        
        # Extract Data 0-9 values using regex
        data_values = [0] * 10
        found_count = 0
        
        for i in range(10):
            pattern = f"Data {i}: (\\d+)"
            match = re.search(pattern, response_text)
            if match:
                data_values[i] = int(match.group(1))
                found_count += 1
                #print(f"[PARSE]: Found Data {i}: {data_values[i]}")
            #else:
                #print(f"[PARSE]: Data {i} not found in response")
        
        #print(f"[PARSE]: Found {found_count}/10 data values")
        #print(f"[PARSE]: Final parsed values: {data_values}")
        
        # Update global probabilities with thread safety
        with serial_lock:
            probabilities = data_values.copy()
            #print(f"[PARSE]: Updated global probabilities: {probabilities}")
        
        return data_values
        
    except Exception as e:
        #print(f"[PARSE ERROR]: {e}")
        import traceback
        traceback.print_exc()
        return [0] * 10

def serial_communication_thread(com_port):
    """Thread function for serial communication with NIOS V"""
    global serial_running, probabilities
    global ser
    
    try:
        # Open serial connection
        ser = serial.Serial(com_port, 115200, timeout=1)
        print(f"✓ Connected to {com_port} at 115200 baud")
        
        # Don't wait for initialization - start polling immediately
        #print("Starting probability polling immediately (FPGA may already be running)...")
        time.sleep(1)  # Just a short delay for connection to stabilize
        
        # Start polling for probabilities
        last_poll_time = time.time()
        poll_interval = 0.1  # 10 times per second
        poll_count = 0
        consecutive_failures = 0
        max_failures = 5  # After 5 consecutive failures, increase interval
        
        while serial_running:
            current_time = time.time()
            
            if current_time - last_poll_time >= poll_interval:
                poll_count += 1
                # Send 'p' command
                #print(f"[SERIAL TX #{poll_count}]: Sending 'p' command")
                ser.write(b'p\r\n')
                ser.flush()  # Make sure data is sent
                time.sleep(0.05)  # Small delay for response
                
                # Read response
                response = ""
                timeout_start = time.time()
                bytes_received = 0
                
                while time.time() - timeout_start < 0.5:  # 500ms timeout
                    if ser.in_waiting > 0:
                        chunk = ser.read(ser.in_waiting).decode('ascii', errors='ignore')
                        bytes_received += len(chunk)
                        response += chunk
                        #print(f"[SERIAL RX #{poll_count}]: +{len(chunk)} bytes: {repr(chunk)}")
                        
                        if "Data 9:" in response:  # We have complete data
                            #print(f"[SERIAL RX #{poll_count}]: Complete response received")
                            break
                    time.sleep(0.01)
                
                if response:
                    #print(f"[SERIAL PARSE #{poll_count}]: Full response ({bytes_received} bytes):")
                    #print(f"  Raw: {repr(response)}")
                    parsed_data = parse_pixel_reader_response(response)
                    #print(f"  Parsed: {parsed_data}")
                    consecutive_failures = 0  # Reset failure counter on success
                else:
                    consecutive_failures += 1
                    #print(f"[SERIAL ERROR #{poll_count}]: No response received to 'p' command (failure #{consecutive_failures})")
                    
                    # If too many consecutive failures, slow down polling
                    if consecutive_failures >= max_failures:
                        #print(f"[SERIAL]: Too many failures, slowing down polling to 1 Hz")
                        poll_interval = 1.0  # Slow down to 1 Hz
                    else:
                        poll_interval = 0.1  # Normal 10 Hz
                
                last_poll_time = current_time
            
            time.sleep(0.01)  # Small sleep to prevent excessive CPU usage
    
    except Exception as e:
        print(f"❌ Serial communication error: {e}")
        import traceback
        traceback.print_exc()
    
    finally:
        if 'ser' in locals():
            ser.close()
        #print("Serial communication thread ended")

def test_serial_connection(com_port):
    """Test serial connection by sending simple commands"""
    try:
        #print(f"\n=== Testing Serial Connection on {com_port} ===")
        ser = serial.Serial(com_port, 115200, timeout=2)
        time.sleep(1)
        
        # Listen for any spontaneous output for 3 seconds
        #print("Listening for spontaneous output for 3 seconds...")
        start_time = time.time()
        while time.time() - start_time < 3:
            if ser.in_waiting > 0:
                data = ser.read(ser.in_waiting()).decode('ascii', errors='ignore')
                #print(f"[SPONTANEOUS]: {repr(data)}")
            time.sleep(0.1)
        
        # Try sending different commands
        test_commands = [b'\r\n', b'help\r\n', b'p\r\n', b'?\r\n', b'status\r\n']
        
        for i, cmd in enumerate(test_commands):
            #print(f"\nTest {i+1}: Sending {repr(cmd)}")
            ser.write(cmd)
            ser.flush()
            time.sleep(0.5)
            
            if ser.in_waiting > 0:
                response = ser.read(ser.in_waiting()).decode('ascii', errors='ignore')
                #print(f"[RESPONSE]: {repr(response)}")
            #else:
                print("[RESPONSE]: No response")
        
        ser.close()
        return True
        
    except Exception as e:
        #print(f"Serial test error: {e}")
        return False
        
def main():
    """Main function with enhanced visualization and serial communication"""
    global serial_running
    global label 
    global radio
    global exposure

    
   
    # COM port selection
    #print("=== NIOS V Probability Display Setup ===")
    com_port = select_com_port()
    if not com_port:
        #print("No COM port selected. Running without serial communication.")
        use_serial = False
    else:
        use_serial = True
    
    # Setup matplotlib for interactive mode
    plt.ion()  # Turn on interactive mode
    fig, ax_image = plt.subplots(1, 1, figsize=(10, 8))
    fig.suptitle('FPGA Video Frame Buffer', fontsize=16)
    
    # Create queue and event for thread communication
    image_queue = Queue()
    stop_event = threading.Event()
    
    # Start capture thread
    capture_thread_obj = threading.Thread(target=capture_thread, args=(image_queue, stop_event))
    capture_thread_obj.daemon = True
    capture_thread_obj.start()
    
    # Start serial communication thread if COM port is available
    serial_thread_obj = None
    if use_serial:
        serial_running = True
        serial_thread_obj = threading.Thread(target=serial_communication_thread, args=(com_port,))
        serial_thread_obj.daemon = True
        serial_thread_obj.start()
    
    #print("Starting real-time visualization...")
    #print("Press Ctrl+C to stop")
    
    try:
        while True:
            try:
               
                # Get new image from queue (non-blocking)
                rgb_image, title = image_queue.get(timeout=0.1)
                
                # Display image
                ax_image.clear()
                ax_image.imshow(rgb_image)
                
                # Add probability text overlay if serial communication is active
                if use_serial:
                    with serial_lock:
                        current_probabilities = probabilities.copy()
                    
                    # Find the highest probability index
                    max_idx = np.argmax(current_probabilities)
                    max_prob = current_probabilities[max_idx]
                    if max_idx < 9:
                        max_idx += 1
                    else:
                        max_idx = 0
                    
                    # Create probability text
                    #prob_text = f"Detected Digit: {max_idx} (Probability: {max_prob})\n"
                    #for i in range(10):
                    #    if i < 9:
                    #        prob_text += f"{i+1}:{current_probabilities[i]} | "
                    #    else:
                    #        prob_text += f"0:{current_probabilities[9]} | "

                    #ax_image.set_title(f"{title}\n{prob_text}", fontsize=16)
                else:
                    ax_image.set_title(f"{title}\n(No Serial Connection)", fontsize=16)
                
                ax_image.axis('off')
                
                plt.tight_layout()
                plt.draw()
                plt.pause(0.01)
                
                #camera_or_paint()
                
            except Empty:
                # No new image available, just update title if probabilities changed
                #camera_or_paint()
                if use_serial:
                    with serial_lock:
                        current_probabilities = probabilities.copy()
                    
                    # Update title with current probabilities
                    max_idx = np.argmax(current_probabilities)
                    max_prob = current_probabilities[max_idx]
                    if max_idx < 9:
                        max_idx += 1
                    else:
                        max_idx = 0
                    
                    prob_text = f"Detected Digit: {max_idx} (Probability: {max_prob})\n"
                    for i in range(10):
                        if i < 9:
                            prob_text += f"{i+1}:{current_probabilities[i]} | "
                        else:
                            prob_text += f"0:{current_probabilities[9]} | "
                    
                    current_title = ax_image.get_title()
                    if "\n" in current_title:
                        base_title = current_title.split("\n")[0]
                        ax_image.set_title(f"{base_title}\n{prob_text}", fontsize=16)
                    
                    plt.draw()
                    plt.pause(0.01)
                
                time.sleep(0.05)  # Small delay to prevent excessive CPU usage
                
    except KeyboardInterrupt:
        print("\nStopping visualization...")
        
    finally:
        # Cleanup
        stop_event.set()
        serial_running = False
        
        # Wait for threads to finish
        if capture_thread_obj.is_alive():
            capture_thread_obj.join(timeout=5)
        
        if serial_thread_obj and serial_thread_obj.is_alive():
            serial_thread_obj.join(timeout=5)
        
        plt.close('all')
        print("Cleanup complete.")

if __name__ == "__main__":
    main()
