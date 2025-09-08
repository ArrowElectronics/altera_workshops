import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.onnx
from torchsummary import summary

# Step 1: Define Net architecture
class Net(nn.Module):
    def __init__(self):
        super(Net, self).__init__()
        self.conv1 = nn.Conv2d(1, 10, kernel_size=5)
        self.conv2 = nn.Conv2d(10, 20, kernel_size=5)
        self.conv2_drop = nn.Dropout2d()
        self.fc1 = nn.Linear(320, 50)
        self.fc2 = nn.Linear(50, 10)

    def forward(self, x):
        x = F.relu(F.max_pool2d(self.conv1(x), 2))
        x = F.relu(F.max_pool2d(self.conv2_drop(self.conv2(x)), 2))
        x = x.view(-1, 320)
        x = F.relu(self.fc1(x))
        x = F.dropout(x, training=self.training)
        x = self.fc2(x)
        return F.softmax(x)


PATH = 'model.pth'

# Step 2: Initialize and load the trained model
model = Net()
model.load_state_dict(torch.load(PATH))

model.eval()

# Step 3: Create a dummy input for the export (batch_size=1, channels=1, height=28, width=28)
dummy_input = torch.randn(1, 1, 28, 28)

# Step 4: Export to ONNX
onnx_model_path = "Digit-classifier.onnx"
torch.onnx.export(model, dummy_input, onnx_model_path)
#torch.onnx.export(model, dummy_input, onnx_model_path, verbose=True)
summary(model, (1,1,28,28), batch_size=1, device='cpu')

print(model)
print(f"Input shape: {dummy_input.shape}")

output = model(dummy_input)
output_shape = output.shape
print(f"Output Shape: {output_shape}")



#help(summary)

