🚀 BEST-AI: Local AI Server Setup v3.0
Professional automated solution for deploying, managing, and exposing local LLMs with Ollama. Developed by Toprak Ahmet Aydoğmuş under Siber Akademi.

🌟 Overview / Genel Bakış
BEST-AI transforms your local machine into a high-performance AI hub in minutes. It automates the tedious setup of drivers, network tunneling, and web interfaces, providing a secure, local-first alternative to cloud AI providers.

Geliştirici Notu: Bu araç, Ollama altyapısını kullanarak kendi yerel yapay zeka sunucunuzu dakikalar içinde kurmanızı, yönetmenizi ve güvenli bir şekilde dış dünyaya açmanızı sağlar.

✨ Key Features / Öne Çıkan Özellikler
🛡️ Core Infrastructure
Zero-Config Deployment: Automatic installation of Ollama on Windows (via Winget) and Linux (via Curl).

Hardware Acceleration: Native detection and configuration for NVIDIA CUDA and AMD ROCm.

Resource Analysis: Real-time monitoring of RAM, Disk, and CPU availability.

🌐 Connectivity & Security
Global Access: One-click deployment of Cloudflare Tunnels or ngrok to access your local AI from anywhere in the world.

Caddy Reverse Proxy: High-performance web server integration for secure API handling.

Security First: Mandatory X-API-Key protection for remote access scenarios.

🎨 Modern Web Experience
Dark/Neon UI: A futuristic Matrix-inspired web interface with built-in Markdown support and syntax highlighting.

Multimodal Ready: Support for text input, file uploads, and Voice Recognition (STT).

Streaming: Real-time response streaming for a ChatGPT-like experience.

🛠️ Technical Menu / Kullanım Menüsü
FAST START: Installs/Starts all services using existing configurations.

FULL SETUP: Complete step-by-step hardware analysis, network config, and model selection.

MODEL MANAGEMENT: Specialized downloader for Llama 3.2, Qwen 2.5, DeepSeek R1, Phi-4, and more.

BENCHMARK: Performance testing to measure your system's tokens per second (TPS).

🚀 Quick Start / Hızlı Başlat
Run the following command in an Administrative PowerShell:

PowerShell
Set-ExecutionPolicy Bypass -Scope Process -Force; .\bestaı.ps1
🗂️ Data Architecture / Dosya Yapısı
The setup centralizes everything in ai_server_data:

/web: Modern HTML5 UI & Caddyfile configuration.

/logs: Comprehensive logs for troubleshooting.

/backups: Automated configuration backups.

config.json: Master server & network state.

👤 Developer & Support / Geliştirici ve Destek
Lead Developer: Toprak Ahmet Aydoğmuş

Company: Siber Akademi

Website: hopp.bio/siberegitim

📝 License
This project is licensed under the MIT License.
