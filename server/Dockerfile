# syntax=docker/dockerfile:1

# Basis-Images mit Version und Digest, damit jeder Build dasselbe Ergebnis
# liefert. Beim Anheben beide Werte erneuern
# (`docker buildx imagetools inspect <image>:<tag>`).
FROM dart:3.12.2@sha256:5ac89dbcae4327278b257920e2786df0f22c87adc630017266b67cfcceef8348 AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart build cli -t bin/server.dart -o /out/server \
 && dart build cli -t bin/manage.dart -o /out/manage \
 && cp /out/manage/bundle/bin/manage /out/server/bundle/bin/

FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
# OFFICE=1: LibreOffice für Vorschau und Archiv-PDF von Word, Excel und
# PowerPoint (macht das Image rund 400 MB größer; Text gibt es auch ohne).
ARG OFFICE=0
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates ocrmypdf poppler-utils qpdf \
      tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng \
 && if [ "$OFFICE" = 1 ]; then apt-get install -y --no-install-recommends \
      libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
      fonts-dejavu-core fonts-liberation2; fi \
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
