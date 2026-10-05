# syntax=docker/dockerfile:1

FROM dart:stable AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart build cli -t bin/server.dart -o /out/server \
 && dart build cli -t bin/manage.dart -o /out/manage \
 && cp /out/manage/bundle/bin/manage /out/server/bundle/bin/

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates ocrmypdf poppler-utils qpdf \
      tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1000 --create-home paperbuddy \
 && mkdir -p /data /consume && chown paperbuddy:paperbuddy /data /consume

COPY --from=build /out/server/bundle /opt/paperbuddy
ENV PATH="/opt/paperbuddy/bin:$PATH" \
    PAPERBUDDY_DATA_DIR=/data \
    PAPERBUDDY_CONSUMPTION_DIR=/consume
VOLUME ["/data", "/consume"]
EXPOSE 8000
USER paperbuddy
HEALTHCHECK --interval=30s --timeout=5s \
  CMD ["sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/8000"]
CMD ["server"]
