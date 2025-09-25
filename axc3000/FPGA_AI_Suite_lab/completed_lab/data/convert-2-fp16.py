import numpy as np
import sys

def convert_to_fp16(input_file, output_file, input_dtype='float32'):
    """
    Convert a binary file to FP16 format.
    
    Parameters:
    - input_file: Path to the input binary file
    - output_file: Path to the output FP16 binary file
    - input_dtype: Data type of the input file (default: 'float32')
    """
    try:
        # Read the binary file into a NumPy array
        data = np.fromfile(input_file, dtype=input_dtype)
        
        # Convert to FP16 (half-precision)
        data_fp16 = data.astype(np.float16)
        
        # Save the FP16 data to a new binary file
        data_fp16.tofile(output_file)
        
        print(f"Successfully converted {input_file} to FP16 and saved as {output_file}")
        print(f"Original size: {data.nbytes} bytes, FP16 size: {data_fp16.nbytes} bytes")
        
    except FileNotFoundError:
        print(f"Error: Input file {input_file} not found")
    except Exception as e:
        print(f"Error during conversion: {str(e)}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python convert_to_fp16.py <input_file> <output_file>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    convert_to_fp16(input_file, output_file)


