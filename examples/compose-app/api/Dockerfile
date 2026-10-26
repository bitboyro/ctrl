FROM python:3.12-alpine
WORKDIR /app
COPY index.html health /app/
EXPOSE 8000
CMD ["python3", "-m", "http.server", "8000", "--bind", "0.0.0.0", "--directory", "/app"]
