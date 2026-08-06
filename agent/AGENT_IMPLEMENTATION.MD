# Lab PC Monitoring Agent

## Overview

Lab PC Monitoring Agent merupakan aplikasi berbasis PowerShell yang bertugas mengirimkan aktivitas komputer Windows ke backend melalui REST API.

Agent dijalankan secara otomatis oleh Windows menggunakan **Task Scheduler** dan **Shutdown Script**.

Karena laboratorium menggunakan **Unified Write Filter (UWF)**, histori Event Viewer tidak dapat dijadikan sumber data permanen. Oleh karena itu, agent akan langsung mengirim event ketika event tersebut terjadi.

---

# Objectives

Windows Agent bertanggung jawab untuk:

- Mengirim event Boot.
- Mengirim event Shutdown.
- Mengirim event Restart.
- Mengirim data ke Backend API.
- Tidak menyimpan histori lokal.

Crash **tidak dikirim oleh agent**, melainkan dideteksi oleh backend.

---

# Folder Structure

Agent akan diinstall pada:

```
C:\ProgramData\LabAgent\
```

Struktur folder:

```
C:\ProgramData\LabAgent

│
├── agent.ps1
├── install.ps1
├── uninstall.ps1
├── config.json
├── logs\
└── cache\
```

## File Description

| File | Description |
|------|-------------|
| agent.ps1 | Main Agent |
| install.ps1 | Install Agent |
| uninstall.ps1 | Remove Agent |
| config.json | Backend Configuration |
| logs | Agent Log |
| cache | Retry Queue (Future) |

---

# Configuration

config.json

```json
{
    "api_url": "http://10.22.65.146:5000/api/events", // url follow the backend api url
    "timeout": 10,
    "retry": 3
}
```

---

# Event Types

| Event | Description |
|------|-------------|
| Boot | Windows selesai startup |
| Shutdown | Shutdown normal |
| Restart | Restart oleh User / Windows Update |

Crash tidak dikirim oleh Agent.

---

# Installation

Jalankan PowerShell sebagai **Administrator**.

```
Set-ExecutionPolicy Bypass -Scope Process

.\install.ps1
```

Installer akan melakukan:

- Membuat folder `C:\ProgramData\LabAgent`
- Menyalin seluruh file Agent
- Membuat Startup Task
- Membuat Restart Event Task
- Mengkonfigurasi Shutdown Script
- Melakukan validasi konfigurasi

---

# Agent Workflow

```
Windows Event

↓

Task Scheduler / Shutdown Script

↓

agent.ps1

↓

Read config.json

↓

Collect Event Information

↓

Build JSON Payload

↓

POST Backend

↓

Done
```

---

# Boot Event

## Trigger

Task Scheduler

### Trigger

```
At Startup
```

### Action

```
Program

powershell.exe
```

Arguments

```
-NoProfile
-ExecutionPolicy Bypass
-File "C:\ProgramData\LabAgent\agent.ps1"
-EventType Boot
```

Run As

```
SYSTEM
```

Run Level

```
Highest Privileges
```

Flow

```
Windows Startup

↓

Task Scheduler

↓

agent.ps1

↓

POST Backend
```

---

# Shutdown Event

Shutdown menggunakan **Shutdown Script**.

```
Computer Configuration

↓

Windows Settings

↓

Scripts

↓

Shutdown
```

Action

```
powershell.exe

-NoProfile

-ExecutionPolicy Bypass

-File "C:\ProgramData\LabAgent\agent.ps1"

-EventType Shutdown
```

Flow

```
Shutdown

↓

Shutdown Script

↓

agent.ps1

↓

POST Backend
```

---

# Restart Event

Restart dideteksi menggunakan Event Viewer.

Provider

```
User32
```

Event ID

```
1074
```

Task Scheduler menggunakan **Event Trigger**.

XML Query

```xml
<QueryList>
    <Query Id="0" Path="System">
        <Select Path="System">
            *[
                System[
                    Provider[@Name='User32']
                    and
                    EventID=1074
                ]
            ]
        </Select>
    </Query>
</QueryList>
```

Action

```
powershell.exe

-NoProfile

-ExecutionPolicy Bypass

-File "C:\ProgramData\LabAgent\agent.ps1"

-EventType Restart
```

Flow

```
Restart

↓

Event ID 1074

↓

Task Scheduler

↓

agent.ps1

↓

POST Backend
```

---

# JSON Payload

Contoh payload yang dikirim ke backend.

```json
{
    "hostname": "LAB-PC-01",
    "event_type": "Boot",
    "message": "Operating System Started",
    "created_at": "2026-08-06T08:00:00"
}
```

---

# Agent Responsibilities

Agent bertanggung jawab untuk:

- Membaca parameter EventType.
- Mengambil informasi event.
- Membaca config.json.
- Membuat JSON Payload.
- Mengirim data ke Backend API.
- Menampilkan error apabila request gagal.

---

# Agent Does NOT Handle

Agent tidak bertanggung jawab untuk:

- Menyimpan histori.
- Menentukan status komputer.
- Mendeteksi Crash.
- Menyimpan data ke database.

Seluruh proses tersebut dilakukan oleh Backend.

---

# install.ps1 Responsibilities

Installer bertanggung jawab untuk:

- Membuat folder ProgramData.
- Menyalin seluruh file Agent.
- Membuat Startup Task.
- Membuat Restart Task.
- Menambahkan Shutdown Script.
- Validasi konfigurasi.
- Menampilkan status instalasi.

---

# uninstall.ps1 Responsibilities

Uninstaller bertanggung jawab untuk:

- Menghapus seluruh Task Scheduler.
- Menghapus Shutdown Script.
- Menghapus folder Agent.
- Membersihkan konfigurasi.

---

# Development Checklist

## Agent

- [ ] agent.ps1
- [ ] config.json
- [ ] HTTP Client
- [ ] JSON Payload Builder
- [ ] Error Handling

## Installer

- [ ] install.ps1
- [ ] uninstall.ps1
- [ ] Startup Task
- [ ] Restart Task
- [ ] Shutdown Script

## Future Improvements

- [ ] Retry Queue
- [ ] Offline Cache
- [ ] Auto Update
- [ ] Windows Service (.NET)
- [ ] Digital Signature
- [ ] MSI Installer