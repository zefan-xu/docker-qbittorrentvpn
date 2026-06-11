FROM python:3.14-alpine@sha256:c5c72336b2060db658391424c48466341838860a9f30efee9280ee53580d9537

WORKDIR /app
COPY server.py /app/server.py

EXPOSE 8080/tcp
ENTRYPOINT ["python", "/app/server.py"]
