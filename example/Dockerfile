FROM python:3.13-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN mkdir -p /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libavcodec61 \
    libavformat61 \
    libavutil59 \
    libswscale8 \
    libjpeg62-turbo \
    libtiff6 \
    libpng16-16t64 \
    libwebp7 \
    libwebpdecoder3 \
    libwebpdemux2 \
    libwebpmux3 \
    libavif16 \
    libopenblas0 \
    liblapacke \
    libgstreamer1.0-0 \
    libgstreamer-plugins-base1.0-0 \
    gstreamer1.0-plugins-good \
    gstreamer1.0-libav \
    gstreamer1.0-libcamera \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

RUN pip3 install --no-cache-dir ./wheels/opencv_python_headless-4.13.0.92-cp313-cp313-linux_aarch64.whl

CMD ["python3", "main.py"]
