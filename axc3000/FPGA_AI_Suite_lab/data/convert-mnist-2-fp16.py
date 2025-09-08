import torch
import torchvision
import numpy as np


def ascii_image(image_input):
	#print("")
	for i in range(28):
		for j in range(28):
			if image_input[i][j] > 0:
				print("*", end="")
			else:
				print("0", end="")
		print("")


test_loader = torch.utils.data.DataLoader(
  torchvision.datasets.MNIST('files/', train=False, download=True,
                             transform=torchvision.transforms.Compose([
                               torchvision.transforms.ToTensor(),
                               torchvision.transforms.Normalize(
                                 (0.1307,), (0.3081,))
                             ])),
  batch_size=1000, shuffle=False)

examples = enumerate(test_loader)
batch_idx, (example_data, example_targets) = next(examples)

#print(example_data.shape)

# Look at only one image
#image = example_data[3][0] #0
#image = example_data[2][0] #1
#image = example_data[1][0] #2
#image = example_data[32][0] #3
#image = example_data[4][0] #4
#image = example_data[23][0] #5
#image = example_data[11][0] #6
#image = example_data[0][0] #7
image = example_data[18][0] #8
#image = example_data[7][0] #9
#ascii_image(image)

for i in range(40):
	print(f"Index: {i}")
	ascii_image(example_data[i][0])

# Convert the PyTorch tensor to a NumPy array
numpy_array = image.numpy()

output_file_name = 'array_hwc_fp16.bin'
# Convert the image to FP16 format
arr_fp16 = numpy_array.astype(np.float16)
# Save the FP16 HWC formatted data to a .bin file
with open(output_file_name, 'wb') as f:
        arr_fp16.tofile(f)
print(f"Converted to {output_file_name}")

