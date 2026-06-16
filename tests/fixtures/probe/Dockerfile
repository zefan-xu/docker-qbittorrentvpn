FROM python:3.14-alpine@sha256:94457973ea8a27a799f0b8ea1fe3e3147fcbebaed63497a8af63b28195a08108

WORKDIR /app
COPY probe.py /app/probe.py

EXPOSE 53/udp 8080/tcp
ENTRYPOINT ["python", "/app/probe.py"]
