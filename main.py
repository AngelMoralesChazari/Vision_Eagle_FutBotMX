import cv2
import supervision as sv
from ultralytics import SAM

print("Cargando")

model = SAM("sam_b.pt")
video_path = "/content/video-893_singular_display.mov"
output_video_path = "/content/partido_segmentado.mp4"

video_info = sv.VideoInfo.from_video_path(video_path = video_path)
mask_annotator = sv.MaskAnnotator()

print(f"Procesando video ({video_info.width}x{video_info.height} a {video_info.fps}")

with sv.VideoSink(target_path = output_video_path, video_info = video_info) as sink:
    for frma in sv.get_video_frames_generator(source_path=video_path):
        result = model(frame, conf=0.25, verbose=False)[0]
        detetions = sv.Detections.from_ultralytics(result)
        annoted_frame = mask_annotator.annotate(scene = frame, detections = detections)
        sink.write_frame(frame = annoted_frame)

print(f"\nVideo Procesado")
print(f"El video completo en: {output_video_path}")