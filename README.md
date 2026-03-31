# Helix AI — Self-hosted RAG for Pharma

![Helix AI Architecture](docs/architecture.png)

**Secure enterprise document Q&A for pharmaceutical R&D and QA teams.**
Data never leaves your local machine. Every response shows exactly where the answer came from.

---

## 🧬 Automated RAG (PharmaCx Integration)

To synchronize documents from **PharmaCx** (DMS/TMS) to **Helix AI** with **zero coding**, use the Shared Hot-Folder method.

### Step 1 — Configure PharmaCx
1.  Navigate to **PharmaCx Document Lifecycle settings**.
2.  Enable the **"Copy on Publish"** feature or similar automatic export.
3.  Set the export path to this shared project folder:
    *   **Shared Path**: `/Users/venkateshwarlu/Documents/published-docs`
4.  Add **OnlyOffice** to this same shared folder structure if you want active editing sessions to be "grounding" the AI in draft content.

### Step 2 — Start the Grounding Heartbeat
The heartbeat script will monitor your shared folder and automatically vectorize everything for the AI:

```bash
./bin/grounding_heartbeat.sh ../published-docs [WORKSPACE_SLUG]
```

### Step 3 — Query in Helix AI
*   Any file you save or publish in PharmaCx will appear in the **Helix AI** search within **10 seconds**.
*   The **`helix-ai`** custom model will answer based on these new documents.

---

## 🚀 Streamlined Setup

Getting started is as easy as one command:

```bash
chmod +x setup.sh bin/*.sh
./setup.sh
```

---

## 🔗 Connection Details (External Apps)

| Detail | Value |
|---|---|
| **Model Name** | `helix-ai` |
| **API Endpoint** | `http://localhost:5055` (Includes Source Attribution) |
| **Why?** | PharmaX/DMS can connect here to get 21 CFR Part 11 compliant AI answers. |

---

*Helix AI — Zero-code RAG synchronization for pharmaceutical workflows.*
