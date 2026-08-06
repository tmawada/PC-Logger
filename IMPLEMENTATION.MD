# Lab PC Monitoring System

## Overview

Lab PC Monitoring System merupakan sistem monitoring aktivitas komputer laboratorium yang bertujuan untuk menyimpan histori aktivitas komputer ke backend.

Project ini dibuat karena laboratorium menggunakan **Unified Write Filter (UWF)** sehingga seluruh histori Windows Event Viewer akan hilang setelah komputer melakukan restart.

Oleh karena itu, histori aktivitas tidak lagi disimpan pada Windows Event Viewer, melainkan langsung dikirim ke backend menggunakan Windows Agent.

---

# Goals

Project ini bertujuan untuk:

- Mengetahui kapan komputer melakukan Boot.
- Mengetahui kapan komputer melakukan Shutdown.
- Mengetahui kapan komputer melakukan Restart.
- Mengetahui apabila komputer mengalami Crash / Unexpected Shutdown.
- Menyimpan histori aktivitas komputer pada PostgreSQL.
- Menyediakan API untuk dashboard monitoring.

---

# Problem Statement

Saat ini laboratorium menggunakan Unified Write Filter (UWF).

Karena UWF aktif:

- Windows Event Viewer akan kembali ke kondisi awal setelah reboot.
- Histori event sebelumnya hilang.
- Tidak memungkinkan menggunakan Event Viewer sebagai histori permanen.

Contoh:

```
Boot
Shutdown
Boot
Shutdown
```

Setelah restart akibat UWF:

```
Boot
```

Event sebelumnya sudah tidak tersedia.

Oleh karena itu diperlukan mekanisme lain untuk menyimpan histori aktivitas komputer.

---

# Proposed Solution

Daripada menyimpan histori pada komputer lokal, setiap event penting akan langsung dikirim ke backend menggunakan REST API.

```
Windows PC

        │

Windows Agent

        │

 REST API

        │

 Flask Backend

        │

 PostgreSQL
```

Dengan pendekatan ini:

- Histori tetap tersedia walaupun UWF aktif.
- Tidak bergantung pada Event Viewer.
- Dapat dimonitor secara realtime.

---

# System Architecture

```
                +----------------------+
                |      Windows PC      |
                +----------------------+
                          │
                          │
                 Windows Agent
                          │
                HTTP POST (JSON)
                          │
                          ▼
                +----------------------+
                |    Flask Backend     |
                +----------------------+
                          │
                    SQLAlchemy ORM
                          │
                          ▼
                +----------------------+
                |     PostgreSQL       |
                +----------------------+
```

---

# Event Types

Agent akan mengirim beberapa jenis event berikut.

| Event | Description |
|--------|-------------|
| Boot | Windows selesai startup |
| Shutdown | Komputer dimatikan secara normal |
| Restart | Komputer melakukan restart |
| Crash | Unexpected shutdown / Power loss |
| Wake *(Future)* | Resume dari Sleep |
| Sleep *(Future)* | Masuk ke mode Sleep |

---

# Event Detection

## Boot

Trigger:

Task Scheduler

```
At Startup
```

Payload

```json
{
    "hostname":"LAB-01",
    "type":"Boot",
    "message":"Operating System Started",
    "timecreated":"2026-08-06T08:00:00"
}
```

---

## Shutdown

Trigger:

Shutdown Script

```
Computer Configuration

↓

Windows Settings

↓

Scripts

↓

Shutdown
```

Payload

```json
{
    "hostname":"LAB-01",
    "type":"Shutdown",
    "message":"Normal Shutdown",
    "timecreated":"2026-08-06T17:00:00"
}
```

---

## Restart

Restart akan dideteksi menggunakan Event ID 1074.

Contoh:

```
Restart by Windows Update

Restart by Explorer

Restart by User
```

Payload

```json
{
    "hostname":"LAB-01",
    "type":"Restart",
    "message":"Restart by Windows Update",
    "timecreated":"2026-08-06T17:00:00"
}
```

---

## Crash

Crash **tidak dapat dikirim secara realtime**.

Alasan:

- Power Loss
- BSOD
- Hard Reset
- Freeze

Komputer langsung mati sehingga Agent tidak memiliki kesempatan mengirim data.

Sebagai gantinya backend akan mendeteksi berdasarkan histori event.

Contoh:

```
Boot

↓

Boot
```

Tanpa ada

```
Shutdown
```

Backend akan membuat event:

```
Crash
```

Message

```
Unexpected Shutdown
```

---

# Event Flow

## Boot

```
Windows Boot

↓

Task Scheduler

↓

Windows Agent

↓

POST /api/log

↓

Backend

↓

PostgreSQL
```

---

## Shutdown

```
Windows Shutdown

↓

Shutdown Script

↓

Windows Agent

↓

POST /api/log

↓

Backend

↓

PostgreSQL
```

---

## Restart

```
Windows Restart

↓

Read Event ID 1074

↓

Windows Agent

↓

POST /api/log

↓

Backend
```

---

## Crash

```
Boot

↓

Boot

↓

Backend Detect

↓

Insert Crash Record
```

---

# Database Schema

## Table

```
pc_logs
```

| Column | Type |
|---------|------|
| id | SERIAL PRIMARY KEY |
| hostname | VARCHAR(100) |
| event_type | VARCHAR(30) |
| message | TEXT |
| created_at | TIMESTAMP |
| received_at | TIMESTAMP DEFAULT NOW() |

---

# API

## POST

```
POST /api/log
```

Request

```json
{
    "hostname":"LAB-01",
    "event_type":"Boot",
    "message":"Operating System Started",
    "created_at":"2026-08-06T08:00:00"
}
```

Response

```json
{
    "success": true
}
```

---

# Backend Structure

```
backend/

│
├── app.py
├── config.py
├── database.py
├── models.py
├── routes.py
├── requirements.txt
├── Dockerfile
└── docker-compose.yml
```

---

# Requirements

```
Flask
Flask-SQLAlchemy
Flask-Migrate
psycopg2-binary
gunicorn
python-dotenv
```

---

# Dockerfile

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

CMD ["gunicorn","-b","0.0.0.0:5000","app:app"]
```

---

# docker-compose.yml

```yaml
version: "3.9"

services:

  postgres:

    image: postgres:16

    container_name: lab-postgres

    restart: always

    environment:
      POSTGRES_DB: lab_inventory
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres

    ports:
      - "5432:5432"

    volumes:
      - postgres_data:/var/lib/postgresql/data

  backend:

    build: .

    container_name: lab-backend

    restart: always

    depends_on:
      - postgres

    ports:
      - "5000:5000"

    environment:
      DB_HOST: postgres
      DB_NAME: lab_inventory
      DB_USER: postgres
      DB_PASSWORD: postgres

volumes:
  postgres_data:
```

---

# Windows Agent Responsibilities

Agent bertanggung jawab untuk:

- Detect Boot.
- Detect Shutdown.
- Detect Restart.
- Mengirim data ke backend.
- Retry apabila backend tidak tersedia.
- Logging apabila terjadi kegagalan request.

---

# Future Improvements

- Dashboard Monitoring
- Online / Offline Status
- Last Seen
- Search Computer
- Export CSV
- Authentication
- Windows Service
- Heartbeat setiap 5 menit
- Wake Detection
- Sleep Detection
- Auto Update Agent

---

# Development Roadmap

## Phase 1 - Backend

- [ ] Membuat Flask Backend
- [ ] Integrasi PostgreSQL
- [ ] SQLAlchemy Model
- [ ] REST API
- [ ] Docker
- [ ] Docker Compose

---

## Phase 2 - Windows Agent

- [ ] Boot Detection
- [ ] Shutdown Detection
- [ ] Restart Detection
- [ ] HTTP Client
- [ ] JSON Payload

---

## Phase 3 - Backend Logic

- [ ] Simpan histori event
- [ ] Detect Crash berdasarkan histori
- [ ] API List Event
- [ ] API Computer Status

---

## Phase 4 - Dashboard

- [ ] Dashboard
- [ ] Search
- [ ] Filter
- [ ] Export
- [ ] Statistics

---

# Notes

Karena laboratorium menggunakan Unified Write Filter (UWF), backend akan menjadi **single source of truth** untuk histori aktivitas komputer.

Windows Agent hanya bertugas mengirim event yang terjadi, sedangkan backend bertugas menyimpan histori, melakukan analisis, dan menentukan status komputer berdasarkan urutan event yang diterima.