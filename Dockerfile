FROM python:3.14-slim

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY . .

# Data directory for SQLite persistence
RUN mkdir -p /app/data

EXPOSE 5000

CMD ["python", "mesh.py"]
