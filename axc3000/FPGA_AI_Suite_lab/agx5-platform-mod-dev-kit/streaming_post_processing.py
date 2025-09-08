import struct
import sys
from typing import Union

"""
    streaming_post_processing.py
    Script for running post processing on streaming data
    output from ED 0_STREAMING
    NOTE this script formats the output into a .txt file with fp16 values
"""


def flip_endianness_128bit(data: Union[bytes, bytearray]) -> bytearray:
    """
    Flip the endianness of each 128-bit chunk in the data.
    Each 128-bit chunk is 16 bytes.
    """
    chunk_size = 16
    num_chunks = len(data) // chunk_size

    flipped_data = bytearray()
    for i in range(num_chunks):
        chunk = data[i * chunk_size: (i + 1) * chunk_size]
        flipped_chunk = chunk[::-1]  # Reverse the bytes in the chunk
        flipped_data.extend(flipped_chunk)

    return flipped_data


def remove_invalid_fp16_values(data: Union[bytes, bytearray]) -> bytearray:
    """
    Remove all FP16 values that are equal to 0xFFFF from the data.
    """
    value_to_remove = 0xFFFF
    # Convert the data to a list of 16-bit unsigned integers
    fp16_values = list(struct.unpack('H' * (len(data) // 2), data))

    # Filter out the values that are equal to value_to_remove
    filtered_values = [value for value in fp16_values if value != value_to_remove]

    # Convert the filtered values back to binary format
    filtered_data = struct.pack('H' * len(filtered_values), *filtered_values)
    return bytearray(filtered_data)


def process_file(input_file: str, output_file: str) -> None:
    """
    Process the input binary file by flipping endianness and removing specific FP16 values.
    """
    with open(input_file, 'rb') as f:
        data = f.read()

    flipped_data = flip_endianness_128bit(data)
    cleaned_data = remove_invalid_fp16_values(flipped_data)

    with open(output_file, 'wb') as f:
        f.write(cleaned_data)


def bin_to_txt(bin_file: str, txt_file: str) -> None:
    """
    Convert the binary file containing FP16 values to a text file.
    """
    # Open the binary file and read the content
    with open(bin_file, 'rb') as f_bin:
        data = f_bin.read()

    # Verify the read binary data length
    print(f"Read {len(data)} bytes from the binary file.")

    # Calculate the number of float16 values
    num_floats = len(data) // 2  # Each float16 is 2 bytes

    # Unpack the binary data into float16 values
    float_data = struct.unpack(f'{num_floats}e', data)

    # Verify unpacked data
    print(f"Unpacked {len(float_data)} float16 values.")

    # Write the float16 values to the text file
    with open(txt_file, 'w') as f_txt:
        for idx, value in enumerate(float_data):
            f_txt.write(f'{idx}: {value}\n')
#       for value in float_data:
#            f_txt.write(f'{value}\n')


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 streaming_post_processing.py <input_file>")
        sys.exit(1)

    input_file: str = sys.argv[1]

    process_file(input_file, "output_pp.bin")
    print("Endianness flipped, 0xFFFF values removed")
    bin_to_txt("output_pp.bin", "result_hw.txt")
    print("Converted binary file to fp16 format, stored in result_hw.txt")
