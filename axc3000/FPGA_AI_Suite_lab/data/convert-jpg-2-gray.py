import torch
from torchvision import transforms
from PIL import Image

# Load the color image (replace 'your_image.jpg' with your image path)
try:
    img = Image.open('your_image.jpg').convert('RGB') # Ensure image is in RGB format
except FileNotFoundError:
    print("Error: 'your_image.jpg' not found. Please provide a valid image path.")
    exit()

# Define the transformation pipeline
transform_pipeline = transforms.Compose([
    transforms.Grayscale(num_output_channels=1),  # Convert to grayscale with 1 channel
    transforms.Resize((28, 28)),                  # Resize to 28x28 pixels
    transforms.ToTensor()                         # Convert PIL Image to PyTorch Tensor
])

# Apply the transformations
grayscale_28x28_tensor = transform_pipeline(img)

# The resulting tensor will have a shape of [1, 28, 28] (Channel, Height, Width)
print(f"Shape of the resulting tensor: {grayscale_28x28_tensor.shape}")

# You can optionally convert it back to a PIL Image to display or save
# to_pil = transforms.ToPILImage()
# grayscale_28x28_image = to_pil(grayscale_28x28_tensor)
# grayscale_28x28_image.show()


