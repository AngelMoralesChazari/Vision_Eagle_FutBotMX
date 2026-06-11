import cv2
import numpy as np
import supervision as sv
from ultralytics import SAM


def main():
    print("Iniciando Pipeline - Vision Eagle")

    # Cargar el modelo
    print("Cargando modelo")
    model = SAM("sam_b.pt")
    video_path = "videos/video-893_singular_display.mov"
    output_video_path = "videos/analisis_final_robots.mp4"

    # 1.- Lectura del video
    video_info = sv.VideoInfo.from_video_path(video_path=video_path)
    print(f"Video cargado correctamente: {video_info.width}x{video_info.height} a {video_info.fps:.2f} FPS")

    # 2. Configurar los anotadores gráficos de Supervision
    mask_annotator = sv.MaskAnnotator(opacity=0.25)
    label_annotator = sv.LabelAnnotator(text_scale=0.4, text_padding=3)
    trace_annotator = sv.TraceAnnotator(trace_length=40, thickness=2)
    heatmap_annotator = sv.HeatMapAnnotator(radius=20, opacity=0.4)

    # 3. Inicializar el Filtro Geográfico y Rastreador (ByteTrack)
    tracker = sv.ByteTrack()

    coordenadas_cancha = np.array([
        [0, int(video_info.height * 0.35)],
        [video_info.width, int(video_info.height * 0.35)],
        [video_info.width, video_info.height],
        [0, video_info.height]
    ])
    zona_cancha = sv.PolygonZone(polygon=coordenadas_cancha)

    print("Procesando cuadros del partido y aplicando filtros")

    # 4. Bucle de procesamiento
    with sv.VideoSink(target_path=output_video_path, video_info=video_info) as sink:
        for frame in sv.get_video_frames_generator(source_path=video_path):

            # Inferencia de IA
            results = model(frame, conf=0.25, verbose=False)[0]
            detections = sv.Detections.from_ultralytics(results)

            # FILTRO 1: Exclusión de Personas
            if detections.class_id is not None:
                detections = detections[detections.class_id != 0]

            # FILTRO 2: Dimensiones por Área
            detections = detections[(detections.area > 2000) & (detections.area < 90000)]

            # FILTRO 3: Zona de la Cancha
            mascara_dentro_cancha = zona_cancha.trigger(detections=detections)
            detections = detections[mascara_dentro_cancha]

            # Actualizar Tracker con datos limpios
            detections = tracker.update_with_detections(detections)

            if detections.tracker_id is not None:
                labels = [f"Robot #{tracker_id}" for tracker_id in detections.tracker_id]
            else:
                labels = []

            # Renderizado por capas de profundidad
            annotated_frame = heatmap_annotator.annotate(scene=frame.copy(), detections=detections)
            annotated_frame = mask_annotator.annotate(scene=annotated_frame, detections=detections)
            annotated_frame = trace_annotator.annotate(scene=annotated_frame, detections=detections)

            if labels:
                annotated_frame = label_annotator.annotate(scene=annotated_frame, detections=detections, labels=labels)

            sink.write_frame(frame=annotated_frame)

    print("\nProceso completado con exito")
    print(f"El video resultante se guardó en: {output_video_path}")


if __name__ == "__main__":
    main()