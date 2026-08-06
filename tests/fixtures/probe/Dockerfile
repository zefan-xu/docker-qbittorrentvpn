FROM python:3.14-alpine@sha256:a1321512d6a287428c50dcdf2ab3857761127e03a23b1f648e9c1c0de59288f8

WORKDIR /app
COPY probe.py /app/probe.py

EXPOSE 53/udp 8080/tcp
ENTRYPOINT ["python", "/app/probe.py"]
