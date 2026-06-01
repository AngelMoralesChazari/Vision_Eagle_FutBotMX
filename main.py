import cv2
import supervision as sv
from ultralytics import SAM

def main():
    print("Iniciando Pipeline - Vision Eagle")

    print("Cargando modelo SAM 3...")
    model = SAM("sam_b.pt")
    video_path = "videos/video-893_singular_display.mov"
    output_video_path = "videos/video_demo_robots.mp4"

    # Lectura del video
    video_info = sv.VideoInfo.from_video_path(video_path=video_path)
    print(f"Video cargado correctamente: {video_info.width}x{video_info.height} a {video_info.fps:.2f} FPS")

    # Configurar los anotadores gráficos de Supervision
    mask_annotator = sv.MaskAnnotator()
    label_annotator = sv.LabelAnnotator()  # Muestra el ID del robot en pantalla
    trace_annotator = sv.TraceAnnotator()  # Dibuja la línea del camino que recorren
    heatmap_annotator = sv.HeatMapAnnotator()  # Genera el mapa de calor dinámico

    # Rastreador Oficial
    tracker = sv.ByteTrack()

    print("Procesando cuadros del partido y aplicando capas de analítica...")

    # Procesamiento de los cuadros
    with sv.VideoSink(target_path = output_video_path, video_info = video_info) as sink:
        for frame in sv.get_video_frames_generator(source_path = video_path):

            # Segmentación
            results = model(frame, conf = 0.25, verbose = False)[0]
            detections = sv.Detections.from_ultralytics(results)

            # Tracker para genrar IDs
            detections = tracker.update_with_detections(detections)

            # Etiquetas basadas en el ID
            if detections.tracker_id is not None:
                labels = [f"Robot #{tracker_id}" for tracker_id in detections.tracker_id]
            else:
                labels = []

            # Renderizado de capas visuales sobre el cuadro original
            annotated_frame = heatmap_annotator.annotate(scene = frame.copy(), detections = detections)
            annotated_frame = mask_annotator.annotate(scene = annotated_frame, detections = detections)
            annotated_frame = trace_annotator.annotate(scene = annotated_frame, detections = detections)

            if labels:
                annotated_frame = label_annotator.annotate(scene = annotated_frame, detections = detections, labels = labels)

            # Guardar el fotograma procesado
            sink.write_frame(frame = annotated_frame)

    print(f"Video final se guardó en: {output_video_path}")


if __name__ == "__main__":
    main()