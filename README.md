🚀 Local AI Server Setup v3.0
Siber Akademi tarafından geliştirilen bu script, Ollama altyapısını kullanarak kendi yerel yapay zeka sunucunuzu dakikalar içinde kurmanızı, yönetmenizi ve dünyaya açmanızı sağlar.

✨ Öne Çıkan Özellikler
Otomatik Kurulum: Windows (Winget/Direct) ve Linux (Curl) sistemlerde tek tıkla kurulum.

Donanım Optimizasyonu: NVIDIA CUDA ve AMD ROCm otomatik algılama ve GPU hızlandırma yapılandırması.

Gelişmiş Web UI: Dark/Neon temalı, dosya yükleme destekli, sesli komut özellikli modern HTML arayüzü.

Global Erişim: Cloudflare Tunnel veya ngrok ile yerel sunucunuzu internete güvenli bir şekilde açma.

Güvenlik: API Key koruması ile yetkisiz erişimi engelleme.

Yönetim Araçları: Model benchmark testi, otomatik güncelleme kontrolü ve yedekleme sistemi.

🛠️ Kurulum
Gereksinimler
Windows 10+ veya modern bir Linux dağıtımı.

PowerShell 5.1+ veya PowerShell Core.

(Önerilen) NVIDIA GPU (CUDA desteği için).

Hızlı Başlat
Projeyi klonlayın veya .ps1 dosyasını indirin, ardından yönetici yetkileriyle çalıştırın:

PowerShell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\bestaı.ps1
🖥️ Kullanım Menüsü
Script çalıştırıldığında sizi interaktif bir ana menü karşılar:

HIZLI BAŞLAT: Mevcut yapılandırma ile tüm servisleri ayağa kaldırır.

Tam Kurulum: Sıfırdan donanım analizi, ağ ayarları ve model seçimlerini yapar.

Model Yönetimi: Popüler modelleri (Llama 3.2, Qwen 2.5, DeepSeek R1 vb.) indirir veya siler.

Servis Kontrol: Ollama ve Caddy servislerini bağımsız yönetir.

Benchmark: Kurulu modellerin sisteminizdeki token/saniye performansını ölçer.

🗂️ Dosya Yapısı
Kurulum sonrası tüm veriler Desktop\ai_server_data (veya script dizini) altında toplanır:

/web: HTML arayüzü ve Caddyfile.

/logs: Tüm servislerin ve kurulumun detaylı kayıtları.

/backups: Kritik yapılandırma yedekleri.

config.json: Sunucu ve ağ ayarlarınız.

🛡️ Güvenlik Notu
Eğer sunucunuzu dış dünyaya (Cloudflare/ngrok) açacaksanız, kurulum aşamasında API Key korumasını aktif etmeniz şiddetle önerilir. API anahtarınız apikey.txt dosyasında saklanır.

Geliştirici: Toprak Ahmet Aydoğmuş

Eğitim Platformu: Siber Akademi
