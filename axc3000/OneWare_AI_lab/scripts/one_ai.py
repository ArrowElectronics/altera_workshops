# image_source_buttons.py
# "Image Source" Tkinter app
# Top-center buttons: "Camera Source" and "Paint Source".
# Canvas: 128x128 logical pixels scaled for drawing, brush width = 3 pixels.
# Right-click cycles palette.
# Bottom buttons: "Save" (writes digit.bin raw RGB R,G,B bytes) and "Clear" (erases canvas).
# Pressing "Camera Source" sets mode to camera and runs camera_stuff().
# Pressing "Paint Source" sets mode to paint and runs paint_stuff().
# Painting allowed only when mode == "paint".

import tkinter as tk
import tkinter as tk
import altera_system_console

import subprocess
from pathlib import Path

WIDTH = 128
HEIGHT = 128
SCALE = 4
CANVAS_W = WIDTH * SCALE
CANVAS_H = HEIGHT * SCALE

PALETTE = ["#000000", "#FF0000", "#00FF00", "#0000FF", "#FFFFFF"]
BRUSH_WIDTH = 3
BRUSH_RADIUS = BRUSH_WIDTH // 2
DEFAULT_BG = "#FFFFFF"

class ImageSourceApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Image Source")
        self.minsize(600, 520)

        # Mode: "paint" or "camera". Default to paint so user can draw immediately.
        self.mode = "paint"

        # Top frame to center the two source buttons
        top_frame = tk.Frame(self)
        top_frame.pack(side="top", fill="x", padx=6, pady=6)
        
        # Centered title across the top frame
        title_label = tk.Label(top_frame, text="ONE WARE AI Demonstration", font=("Segoe UI", 14, "bold"))
        title_label.pack(side="top", fill="x")
        title_label.config(anchor="center")        

        center_holder = tk.Frame(top_frame)  # packed without fill -> centered
        center_holder.pack()

        self.btn_camera = tk.Button(center_holder, text="Camera Source", command=self._on_camera_pressed)
        self.btn_paint = tk.Button(center_holder, text="Paint Source", command=self._on_paint_pressed)
        self.btn_camera.pack(side="left", padx=8)
        self.btn_paint.pack(side="left", padx=8)

        # Canvas (paint area)
        self.canvas = tk.Canvas(self, width=CANVAS_W, height=CANVAS_H, highlightthickness=1, bg=DEFAULT_BG)
        self.canvas.pack(side="top", padx=6, pady=(6,6))

        # Pixel buffer (R,G,B) initialized white
        self.pixels = bytearray([255] * (WIDTH * HEIGHT * 3))

        # Rectangle items for each logical pixel (for fast visual updates)
        self.rect_ids = [[None] * WIDTH for _ in range(HEIGHT)]
        for y in range(HEIGHT):
            y0 = y * SCALE
            y1 = y0 + SCALE
            for x in range(WIDTH):
                x0 = x * SCALE
                x1 = x0 + SCALE
                self.rect_ids[y][x] = self.canvas.create_rectangle(x0, y0, x1, y1, outline="", fill=DEFAULT_BG)

        # Painting state
        self.current_color_index = 0
        self.current_color = PALETTE[self.current_color_index]
        self._last_center = None

        # Bind paint events
        self.canvas.bind("<Button-1>", self._on_left_down)
        self.canvas.bind("<B1-Motion>", self._on_left_drag)
        self.canvas.bind("<ButtonRelease-1>", self._on_left_up)
        self.canvas.bind("<Button-3>", self._on_right_click)

        # Bottom frame for Save and Clear buttons
        bottom_frame = tk.Frame(self)
        bottom_frame.pack(side="bottom", fill="x", padx=6, pady=6)
        self.btn_save = tk.Button(bottom_frame, text="Save", command=self.on_save)
        self.btn_clear = tk.Button(bottom_frame, text="Clear", command=self.on_clear)
        self.btn_save.pack(side="right", padx=4)
        self.btn_clear.pack(side="right", padx=4)

        # Initialize cursor for current mode
        self._update_cursor()
        
        # default to paint when first running
        self.on_clear()
        self._on_paint_pressed()        
        altera_system_console.execute_camera()

    # ----- Mode button handlers -----
    def _on_camera_pressed(self):
        self.mode = "camera"
        self._update_cursor()
        self.on_clear()
        try:
            self.camera_stuff()
        except Exception as e:
            #print("camera_stuff error:", e)
            x = 1

    def _on_paint_pressed(self):
        self.mode = "paint"
        self._update_cursor()
        try:
            self.paint_stuff()
        except Exception as e:
            #print("paint_stuff error:", e)
            x = 1

    def _update_cursor(self):
        if self.mode == "paint":
            self.canvas.config(cursor="crosshair")
        else:
            self.canvas.config(cursor="arrow")
        self._last_center = None

    # ----- Placeholder work functions (user replaces with real logic) -----
    def camera_stuff(self):
        # Run-once camera action invoked when Camera Source pressed.
        altera_system_console.execute_camera() 

    def paint_stuff(self):
        # Run-once paint action invoked when Paint Source pressed.
        altera_system_console.execute_paint()

    # ----- Save / Clear -----
    def on_save(self):
        try:
            with open("digit.bin", "wb") as f:
                f.write(self.pixels)
            #print("Saved digit.bin")
            self.paint_stuff()
        except Exception as e:
            #print("Save failed:", e)
            x = 1

    def on_clear(self):
        # Erase canvas and reset pixel buffer to white
        for i in range(0, len(self.pixels), 3):
            self.pixels[i] = 255
            self.pixels[i+1] = 255
            self.pixels[i+2] = 255
        for y in range(HEIGHT):
            for x in range(WIDTH):
                self.canvas.itemconfig(self.rect_ids[y][x], fill=DEFAULT_BG)
        self._last_center = None
        self.canvas.update_idletasks()
        self.on_save()
 

    # ----- Painting handlers -----
    def _on_left_down(self, event):
        self._paint_at_event(event)

    def _on_left_drag(self, event):
        self._paint_at_event(event)

    def _on_left_up(self, event):
        self._last_center = None

    def _on_right_click(self, event):
        # Cycle palette
        self.current_color_index = (self.current_color_index + 1) % len(PALETTE)
        self.current_color = PALETTE[self.current_color_index]
        #print("Color:", self.current_color)

    def _paint_at_event(self, event):
        # Allow painting only when mode is "paint"
        if self.mode != "paint":
            return
        cx = int(event.x // SCALE)
        cy = int(event.y // SCALE)
        if cx < 0 or cx >= WIDTH or cy < 0 or cy >= HEIGHT:
            return
        if self._last_center == (cx, cy):
            return
        self._last_center = (cx, cy)
        r = int(self.current_color[1:3], 16)
        g = int(self.current_color[3:5], 16)
        b = int(self.current_color[5:7], 16)
        for dy in range(-BRUSH_RADIUS, BRUSH_RADIUS + 1):
            for dx in range(-BRUSH_RADIUS, BRUSH_RADIUS + 1):
                x = cx + dx
                y = cy + dy
                if 0 <= x < WIDTH and 0 <= y < HEIGHT:
                    idx = (y * WIDTH + x) * 3
                    self.pixels[idx] = r
                    self.pixels[idx + 1] = g
                    self.pixels[idx + 2] = b
                    self.canvas.itemconfig(self.rect_ids[y][x], fill=self.current_color)

if __name__ == "__main__":
    app = ImageSourceApp()
    app.mainloop()
