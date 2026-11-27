# Mini-SIEM — Rozproszony System Korelacji Logów i Mobilna Aplikacja Zgłaszania Incydentów

Kompleksowy system klasy **mini-SIEM** (Security Information and Event Management) realizowany w wariancie **„jeden system w dwóch odsłonach”** (Projekt 1: rozproszony backend kontenerowy + Projekt 2: aplikacja mobilna *offline-first* z bezpiecznym kanałem komunikacji).

System zbiera logi bezpieczeństwa i zgłoszenia incydentów z terenu, analizuje je asynchronicznie pod kątem znanych sygnatur ataków oraz korelacji czasowej, przechowuje wyniki w relacyjnej bazie danych, wizualizuje je na żywo w Grafanie oraz wysyła powiadomienia Push (FCM) bezpośrednio na telefony analityków.

---

## Spis treści

1. [Architektura całego systemu](#1-architektura-całego-systemu)
2. [Co od czego jest — Backend (repozytorium `mini-siem`)](#2-co-od-czego-jest--backend-repozytorium-mini-siem)
3. [Co od czego jest — Aplikacja mobilna (repozytorium `mini-siem-mobile`)](#3-co-od-czego-jest--aplikacja-mobilna-repozytorium-mini-siem-mobile)
4. [Jak to działa krok po kroku (przepływy danych)](#4-jak-to-działa-krok-po-kroku-przepływy-danych)
5. [Dokumentacja REST API (Endpointy)](#5-dokumentacja-rest-api-endpointy)
6. [Ważne adresy URL i zarządzanie kontami](#6-ważne-adresy-url-i-zarządzanie-kontami)
7. [Uruchomienie, budowanie i CI/CD](#7-uruchomienie-budowanie-i-cicd)
8. [Testy automatyczne, testy awarii i pomiary wydajności](#8-testy-automatyczne-testy-awarii-i-pomiary-wydajności)
9. [Zespół projektowy](#9-zespół-projektowy)

---

## 1. Architektura całego systemu

```text
+-----------------------------------+          +----------------------------------------+
|   Aplikacja Mobilna (Flutter)     |          |   Generator Ruchu / Testy (Locust)     |
| - Lokalna baza Hive (offline)     |          | - SIEMLoadTester (logi HTTP/ataki)     |
| - Skaner QR (aparat) + GPS        |          | - MobileAppUser (JWT + Delta + LWW)    |
| - Delta Sync (?since=) + LWW      |          +-------------------+--------------------+
| - HTTPS + Certificate Pinning     |                              |
| - Logowanie JWT / offline SHA-256 |                              | REST HTTP (:8080)
+--------+------------------+-------+                              |
         |                  ^                                      |
         | HTTPS (:8443)    | Powiadomienia Push                   |
         | JWT + Pinning    | (Firebase Cloud Messaging)           |
         v                  |                                      v
+---------------------------------------------------------------------------------------+
|                      Nginx (Reverse Proxy / Load Balancer)                            |
|               HTTP :8080  |  HTTPS :8443 (TLS)  |  Round-Robin                        |
+-------------------+---------------------------+---------------------------+-----------+
                    |                           |                           |
                    v                           v                           v
          +-------------------+       +-------------------+       +-------------------+
          |   collector-1     |       |   collector-2     |       |   collector-3     |
          | FastAPI + GZip    |       | FastAPI + GZip    |       | FastAPI + GZip    |
          | PooledDB (MySQL)  |       | PooledDB (MySQL)  |       | PooledDB (MySQL)  |
          +---------+---------+       +---------+---------+       +---------+---------+
                    |                           |                           |
                    +-------------+-------------+-------------+-------------+
                                  |                           |
          (Asynchronicznie: RPUSH)|                           | (Odczyt / PATCH LWW / JWT)
                                  v                           v
                         +-----------------+         +-----------------+
                         |  Redis (:6379)  |         |  MySQL (:3306)  |
                         |   logs_queue    |         |  baza: siemdb   |
                         +--------+--------+         | - raw_logs      |
                                  |                  | - alerts        |
             (Blokujące: BLPOP)   v                  | - users         |
                         +-----------------+         | - device_tokens |
                         |    Analyzer     |-------->+--------+--------+
                         | Python Worker   | (Zapis           |
                         | - Sygnatury     |  logów i         |
                         | - Brute-Force   |  alertów)        |
                         | - Firebase FCM  |                  |
                         +-----------------+                  |
                                                              |
+-------------------------------------------------------------+-------------------------+
| MONITORING I WIZUALIZACJA:                                                            |
|  [collector-1/2/3 /metrics] --> [Prometheus :9090] --> [Grafana :3000] <-- [MySQL]    |
+---------------------------------------------------------------------------------------+
```

---

## 2. Co od czego jest — Backend (repozytorium `mini-siem`)

Cały backend działa w architekturze kontenerowej (**10 kontenerów** uruchamianych jednym poleceniem `docker compose up -d --build`).

### 2.1. Kontenery (usługi w `docker-compose.yml`)

| Usługa | Obraz / Technologia | Port | Za co odpowiada |
| :--- | :--- | :---: | :--- |
| **`nginx`** | `nginx:alpine` | `8080` (HTTP)<br>`8443` (HTTPS) | Brama wejściowa i Load Balancer. Szyfruje ruch TLS dla aplikacji mobilnej, przekazuje prawdziwy adres IP klienta (`X-Real-IP`) i rozkłada ruch algorytmem *Round-Robin* na 3 repliki Collectora. W razie awarii jednej instancji automatycznie kieruje ruch na pozostałe. |
| **`collector-1`<br>`collector-2`<br>`collector-3`** | Python 3.11 + FastAPI + Uvicorn | wewnętrzny `8000` | Skalowana poziomo (3 instancje) bezstanowa warstwa REST API. Obsługuje logowanie JWT, rejestrację tokenów FCM, przyjmowanie logów/incydentów do kolejki Redis, odczyt alertów (Delta Sync + GZip), rozwiązywanie konfliktów LWW, dokumentację Swagger UI (`/docs`) oraz metryki `/metrics`. |
| **`redis`** | `redis:alpine` | `6379` | Broker komunikatów realizujący komunikację asynchroniczną. Buforuje napływające logi w liście FIFO `logs_queue` (`RPUSH` / `BLPOP`), chroniąc bazę danych przed przeciążeniem w chwilach dużego ruchu. |
| **`analyzer`** | Python 3.11 (worker) | — | Silnik korelacji i detekcji zagrożeń działający w tle. Wyciąga logi z Redisa, zapisuje surowe zdarzenia do MySQL, dopasowuje sygnatury ataków, zlicza próby Brute-Force, obsługuje zgłoszenia z aplikacji mobilnej oraz wysyła powiadomienia Push (Firebase FCM z cooldownem 5 s). |
| **`db`** | `mysql:8.0` | `3306` | Relacyjna baza danych (`siemdb`) z trwałym wolumenem `mysql_data`. Przechowuje tabele: `raw_logs` (wszystkie zdarzenia), `alerts` (wykryte incydenty + statusy LWW + metadane QR/GPS), `users` (konta i hashe PBKDF2) oraz `device_tokens` (tokeny Push FCM). |
| **`prometheus`** | `prom/prometheus` | `9090` | Centralny system zbierania metryk. Co 5 sekund odpytuje `/metrics` na wszystkich trzech instancjach Collectora (RPS, opóźnienia HTTP, kody błędów, status węzłów `up`). |
| **`grafana`** | `grafana/grafana` | `3000` | Panel wizualizacji z automatycznym provisioningiem (`grafana/provisioning/`). Wyświetla na jednym dashboardzie jednocześnie metryki wydajnościowe z Prometheusa oraz tabelę wykrytych alertów pobieraną wprost z MySQL. |
| **`locust`** | `locustio/locust` | `8089` | Webowe narzędzie do testów obciążeniowych z przełącznikiem scenariuszy (`--class-picker`): pozwala testować zarówno strumień logów P1 (`SIEMLoadTester`), jak i użytkowników aplikacji mobilnej P2 (`MobileAppUser`). |

### 2.2. Struktura plików backendu (podział na warstwy)

```text
mini-siem/
├── docker-compose.yml              # Definicja wszystkich 10 kontenerów, sieci i wolumenów
├── prometheus.yml                  # Konfiguracja celów scrapowania (collector-1/2/3:8000)
├── nginx/
│   ├── nginx.conf                  # Konfiguracja upstreamów (3x Collector), HTTP/HTTPS i failover
│   └── certs/                      # Certyfikat TLS dla portu 8443 (odcisk SHA-256 przypięty w apce)
├── collector/                      # Usługa API podzielona na 5 warstw:
│   ├── Dockerfile                  # Budowanie obrazu Collectora (kopiuje wszystkie moduły)
│   ├── requirements.txt            # Zależności (FastAPI, DBUtils, PyJWT, PyMySQL, Redis, Prometheus)
│   ├── config.py                   # Warstwa konfiguracji: zmienne środowiskowe, limity puli DB, JWT
│   ├── database.py                 # Warstwa danych: pula połączeń PooledDB (max=20), get_db(), init_db()
│   ├── security.py                 # Warstwa bezpieczeństwa: PBKDF2-HMAC-SHA256, JWT HS256, parsowanie UTC
│   ├── schemas.py                  # Warstwa walidacji: modele Pydantic (LogEvent, MobileIncident, LWW)
│   └── main.py                     # Warstwa routingu: endpointy REST, CORS, GZipMiddleware, Prometheus
├── analyzer/
│   ├── Dockerfile                  # Budowanie obrazu workera (python -u worker.py)
│   ├── requirements.txt            # Zależności (redis, pymysql, cryptography, firebase-admin)
│   └── worker.py                   # Konsument kolejki Redis, reguły detekcji, zapis MySQL, wysyłka FCM
├── grafana/
│   └── provisioning/
│       ├── datasources/            # Automatyczne podpięcie źródeł Prometheus i MySQL
│       └── dashboards/             # Gotowy dashboard JSON (alerty + metryki klastra)
├── generator/
│   └── generate_traffic.py         # Symulator ruchu HTTP i ataków do demonstracji na żywo
├── tests/
│   ├── test.py                     # Testy jednostkowe (4 testy detekcji sygnatur w Analyzerze)
│   ├── test_integration.py         # Test integracyjny E2E (Nginx -> Collector -> Redis -> Analyzer -> MySQL)
│   ├── test_mobile_lww.py          # Testy integracyjne API mobilnego (JWT, incydenty, LWW, Delta Sync)
│   ├── locustfile.py               # Scenariusz obciążeniowy P1 (SIEMLoadTester)
│   └── locustfile_mobile.py        # Scenariusz obciążeniowy P2 (MobileAppUser)
├── .github/workflows/
│   └── deploy.yml                  # Pipeline CI/CD uruchamiany na Self-Hosted Runnerze po pushu na main
└── docs/spotkania/                 # Notatki z cotygodniowych spotkań zespołu
```

> **Bezpieczeństwo klucza Firebase po stronie backendu:** Plik `serviceAccountKey.json` (klucz prywatny konta usługowego Firebase Admin SDK) nie znajduje się w repozytorium Git. Jest przechowywany poza katalogiem roboczym runnera w `/home/user/siem-secrets/serviceAccountKey.json` i montowany w kontenerze `analyzer` tylko do odczytu (`/app/firebase:ro`).

---

## 3. Co od czego jest — Aplikacja mobilna (repozytorium `mini-siem-mobile`)

Aplikacja napisana we **Flutterze (Dart)** z przeznaczeniem na system Android (testowana na fizycznym urządzeniu Samsung Galaxy S23 Ultra). Zaprojektowana w architekturze warstwowej w podejściu **offline-first**.

### 3.1. Struktura plików aplikacji mobilnej

```text
mini-siem-mobile/
├── pubspec.yaml                            # Zależności: hive_flutter, http, connectivity_plus, crypto,
│                                           # mobile_scanner, geolocator, firebase_core, firebase_messaging
├── lib/
│   ├── main.dart                           # Punkt startowy: pomiar czasu startu (startupMs),
│   │                                       # inicjalizacja SyncService i PushService, wybór ekranu
│   ├── config.dart                         # Adres backendu (https://serwer1pk:8443) i odcisk SHA-256
│   │                                       # certyfikatu TLS do Certificate Pinning
│   ├── models/
│   │   └── alert_model.dart                # Warstwa modelu: typowana klasa AlertItem (serializacja JSON/Hive)
│   ├── storage/
│   │   └── box_store.dart                  # Warstwa persystencji: abstrakcja BoxStore z implementacją
│   │                                       # HiveBoxStore (dysk telefonu) oraz MemoryBoxStore (testy w RAM)
│   ├── services/
│   │   ├── http_client_io.dart             # Klient HTTP z wymuszonym TLS Certificate Pinning (SHA-256)
│   │   ├── http_client_stub.dart           # Zaślepka klienta HTTP dla środowisk bez dart:io
│   │   ├── push_service.dart               # Integracja Firebase Cloud Messaging: uprawnienia, token FCM,
│   │   │                                   # obsługa onMessage, onMessageOpenedApp i getInitialMessage
│   │   └── sync_service.dart               # Rdzeń logiki biznesowej (ChangeNotifier):
│   │                                       # - logowanie JWT online + weryfikacja offline SHA-256 + re-auth
│   │                                       # - aktywne sprawdzanie serwera (/health)
│   │                                       # - kolejki offline (incydenty + zmiany statusów)
│   │                                       # - synchronizacja przyrostowa (Delta Sync ?since=)
│   │                                       # - obsługa konfliktów LWW i zbieranie telemetrii
│   └── screens/                            # Warstwa prezentacji (interfejs użytkownika):
│       ├── login_screen.dart               # Ekran logowania (brak auto-logowania po starcie aplikacji)
│       ├── home_screen.dart                # Główny widok z paskiem ONLINE/OFFLINE, banerami LWW i PUSH,
│       │                                   # dolną nawigacją i cyklicznym auto-odświeżaniem (10 s)
│       ├── alerts_tab.dart                 # Lista alertów z bazy lokalnej/serwera + zmiana statusu (LWW)
│       ├── report_incident_tab.dart        # Formularz zgłoszenia incydentu (QR, opcjonalne IP, priorytet, GPS)
│       ├── qr_scanner_page.dart            # Podgląd aparatu i skaner kodów QR (mobile_scanner)
│       └── metrics_sheet.dart              # Panel pomiarowy: startupMs, lastSyncMs, bajty, Delta/Full Sync,
│                                           # reset liczników oraz historia rozwiązanych konfliktów LWW
├── android/
│   └── app/
│       ├── google-services.json.template   # Szablon konfiguracji Firebase (bez klucza API)
│       ├── build.gradle.kts                # Konfiguracja Androida i wtyczka Google Services
│       └── src/main/AndroidManifest.xml    # Uprawnienia: INTERNET, CAMERA, LOCATION, POST_NOTIFICATIONS
├── test/
│   ├── lww_offline_test.dart               # 6 testów jednostkowych (LWW, konflikty, login offline, Delta Sync)
│   └── ui_flow_test.dart                   # Test widgetowy UI (logowanie, alerty, kolejka offline, sync)
├── integration_test/
│   └── app_test.dart                       # Test integracyjny E2E uruchamiany na fizycznym urządzeniu/emulatorze
└── .github/workflows/
    └── build-apk.yml                       # CI/CD: wstrzyknięcie FIREBASE_API_KEY z GitHub Secrets,
                                            # uruchomienie flutter test, budowa i publikacja app-release.apk
```

---

## 4. Jak to działa krok po kroku (przepływy danych)

### 4.1. Przepływ logów i wykrywanie zagrożeń (Backend)

1. Klient (generator ruchu, Locust lub aplikacja mobilna) wysyła zdarzenie JSON na Nginx (`POST /api/v1/logs` lub `POST /api/v1/incidents`).
2. Nginx przekazuje żądanie metodą *Round-Robin* do jednej z trzech instancji Collectora (`collector-1`, `collector-2`, `collector-3`).
3. Collector waliduje dane modelem Pydantic, wrzuca zdarzenie na koniec kolejki `logs_queue` w Redisie (`RPUSH`) i natychmiast zwraca kod `202 Accepted` wraz z nazwą węzła (`handled_by_instance`). Dzięki temu Collector nie czeka na zapis dyskowy w bazie MySQL.
4. `Analyzer` odbiera zdarzenie blokującym wywołaniem `BLPOP logs_queue` i realizuje trzy zadania:
   * **Zapis surowego logu:** wpis trafia do tabeli `raw_logs`.
   * **Detekcja sygnaturowa (bezstanowa):** analizuje pole `payload` pod kątem wzorców:
     * `SQL_INJECTION` (`' OR 1=1`, `UNION SELECT`, `DROP TABLE`, `--`),
     * `PATH_TRAVERSAL` (`../../etc/passwd`, `..\..\windows`, `/etc/shadow`),
     * `XSS_ATTACK` (`<script>`, `alert(`, `onerror=`).
   * **Korelacja zdarzeń w czasie (stanowa):** zlicza zdarzenia `LOGIN_FAILED` osobno dla każdego adresu `source_ip`. Po wykryciu 5 nieudanych prób generuje alert `BRUTE_FORCE_DETECTED` i zeruje licznik.
   * **Zgłoszenia mobilne:** zdarzenia typu `MOBILE_INCIDENT` zapisuje bezpośrednio jako alerty z przypisanym `asset_id` (kod QR), współrzędnymi GPS (`latitude`, `longitude`) i nazwą analityka (`reported_by`).
5. Dla każdego nowo zapisanego alertu `Analyzer` wysyła powiadomienie **Push (Firebase Cloud Messaging)** na wszystkie zarejestrowane tokeny w tabeli `device_tokens` (z zabezpieczeniem przeciwzalewowym — cooldown 5 sekund między kolejnymi powiadomieniami).

### 4.2. Bezpieczeństwo i uwierzytelnianie (Online + Offline)

* **Szyfrowany kanał i Certificate Pinning:** Aplikacja łączy się wyłącznie przez `HTTPS (:8443)` i weryfikuje odcisk SHA-256 certyfikatu serwera zapisany w `lib/config.dart`. Zapobiega to atakom typu *Man-in-the-Middle* (MITM).
* **Brak automatycznego logowania:** Stan odblokowania sesji istnieje wyłącznie w pamięci RAM — po zamknięciu i ponownym uruchomieniu aplikacji użytkownik musi ponownie podać dane logowania.
* **Logowanie online (JWT):** Zapytanie `POST /api/v1/login` weryfikuje hasło po stronie serwera (PBKDF2-HMAC-SHA256, 100 000 iteracji) i zwraca token JWT (`HS256`, ważny 8 godzin). Aplikacja zapisuje token oraz lokalny, posolony skrót **SHA-256** poświadczeń w bazie Hive.
* **Logowanie offline + ponowna weryfikacja (re-auth):** Gdy telefon nie ma połączenia z serwerem, aplikacja weryfikuje wpisany login i hasło względem lokalnego skrótu SHA-256 w Hive. Błędne hasło jest odrzucane, a poprawne otwiera sesję lokalną (pasek `OFFLINE (AUTORYZACJA OFFLINE)`). Po powrocie sieci `syncAll()` automatycznie weryfikuje sesję z serwerem przed wysłaniem kolejki zmian — jeśli konto zostało zmienione lub zablokowane (`401`), sesja zostaje natychmiast wylogowana.

### 4.3. Tryb Offline, Synchronizacja przyrostowa (Delta Sync) i Oszczędzanie energii

* **Aktywne wykrywanie utraty serwera:** Aplikacja nie polega wyłącznie na ikonie Wi-Fi/LTE w systemie Android — przy odświeżaniu wywołuje `GET /health` z timeoutem 4 s. Jeśli serwer lub VPN nie odpowiada, górny pasek natychmiast zmienia kolor na **czerwony (`OFFLINE`)**, a wszystkie nowe zgłoszenia incydentów i zmiany statusów trafiają do trwałych kolejek w lokalnej bazie **Hive** (`pending_incidents_box`, `pending_updates_box`).
* **Synchronizacja przyrostowa (Delta Sync):** Pierwsze pobranie alertów wykonuje pełny odczyt (`Full Sync`, do 50 najnowszych rekordów) i zapisuje największy znacznik `updated_at`. Każda kolejna synchronizacja wysyła parametr `?since=<ostatni_updated_at>`, dzięki czemu serwer przesyła wyłącznie nowe lub zmodyfikowane alerty (a przy braku zmian pustą listę `[]` o rozmiarze 2 bajtów), dodatkowo kompresując większe odpowiedzi przez `GZipMiddleware`.
* **Odświeżanie przyjazne baterii:** Gdy aplikacja jest otwarta na ekranie, wykonuje lekki Delta Sync co 10 sekund. Po przejściu w tło (`AppLifecycleState.paused`) timer jest całkowicie zatrzymywany — telefon pozostaje w spoczynku i reaguje dopiero na powiadomienie **Push FCM** lub powrót użytkownika na pierwszy plan (kliknięcie w powiadomienie z paska automatycznie uruchamia `syncAll()`).

### 4.4. Rozwiązywanie konfliktów — Last-Write-Wins (LWW)

Gdy użytkownik zmieni status alertu w trybie offline, aplikacja zapisuje zmianę w kolejce wraz ze znacznikiem czasu **UTC (`client_updated_at`)**. Po odzyskaniu połączenia wysyła `PATCH /api/v1/alerts/{id}`:

* Jeśli `client_updated_at >= server.updated_at` -> **wygrywa telefon (`winner: client`)**. Serwer aktualizuje status w bazie MySQL, a na telefonie pojawia się zielony baner `LWW #<id>: wygrał TELEFON`.
* Jeśli `client_updated_at < server.updated_at` -> **wygrywa serwer (`winner: server`)**. Serwer zwraca `conflict_resolved: true` oraz swoją aktualną wersję alertu, aplikacja nadpisuje stan lokalny wersją z serwera, wyświetla pomarańczowy baner `Konflikt LWW #<id>: wygrał SERWER` i dopisuje zdarzenie do historii konfliktów w panelu pomiarów.

### 4.5. Funkcje sprzętowe urządzenia

* **Aparat (skaner kodów QR):** przycisk *Skanuj* na zakładce *Zgłoś incydent* otwiera podgląd kamery (`mobile_scanner`) i automatycznie wypełnia pole `ID komputera / serwera` na podstawie zeskanowanego kodu QR ze sprzętu w laboratorium/serwerowni.
* **Lokalizacja GPS:** przycisk *Pobierz GPS* odczytuje bieżące współrzędne geograficzne (`geolocator`) i dołącza je do zgłoszenia incydentu (wraz z opcjonalnym adresem IP źródłowym — gdy pole IP zostaje puste, backend automatycznie odczytuje adres IP klienta z nagłówka `X-Real-IP`).

---

## 5. Dokumentacja REST API (Endpointy)

Pełna interaktywna dokumentacja OpenAPI/Swagger dostępna jest pod adresem `/docs`.

| Metoda i ścieżka | Auth (JWT) | Opis działania |
| :--- | :---: | :--- |
| `POST /api/v1/login` | Nie | Logowanie użytkownika (`username`, `password`). Zwraca token `access_token` (Bearer JWT) oraz rolę. |
| `POST /api/v1/devices` | Tak | Rejestracja tokenu `fcm_token` urządzenia mobilnego w bazie MySQL (pod powiadomienia Push). |
| `POST /api/v1/logs` | Nie | Przyjęcie pojedynczego logu sieciowego/systemowego i wrzucenie go do kolejki Redis (`202 Accepted`). |
| `POST /api/v1/incidents` | Tak | Zgłoszenie incydentu z aplikacji mobilnej (QR `asset_id`, `description`, `severity`, opcjonalne `source_ip`, GPS, `client_created_at`). |
| `GET /api/v1/alerts?limit=50&since=...` | Nie | Pobranie listy wykrytych alertów. Opcjonalny parametr `since` (ISO-8601 UTC) włącza **Delta Sync**. |
| `PATCH /api/v1/alerts/{alert_id}` | Tak | Zmiana statusu alertu (`NEW`, `IN_PROGRESS`, `RESOLVED`) z rozstrzyganiem konfliktów **LWW** na podstawie `client_updated_at`. |
| `GET /api/v1/logs?limit=50` | Nie | Odczyt ostatnich surowych logów z tabeli `raw_logs`. |
| `GET /health` | Nie | Szybki ping dostępności usługi (wykorzystywany przez aplikację mobilną do detekcji stanu `ONLINE`/`OFFLINE`). |
| `GET /api/v1/health/{target}` | Nie | Diagnostyka klastra (`all`, `collector-1`, `collector-2`, `collector-3`, `random`) + status Redisa i MySQL. |
| `GET /metrics` | Nie | Metryki wydajnościowe w formacie Prometheusa. |

---

## 6. Ważne adresy URL i zarządzanie kontami

*(Dla dostępu z komputera/telefonu w sieci VPN adres hosta to `serwer1pk`; lokalnie na serwerze: `localhost`.)*

| Usługa | Adres URL | Dane logowania / Uwagi |
| :--- | :--- | :--- |
| **Swagger UI (HTTP / HTTPS)** | `http://serwer1pk:8080/docs`<br>`https://serwer1pk:8443/docs` | Interaktywne testowanie wszystkich endpointów API |
| **Grafana (Dashboard SIEM)** | `http://serwer1pk:3000` | Login: `admin` / Hasło: `admin` |
| **Locust (Testy obciążenia)** | `http://serwer1pk:8089` | Wybór scenariusza: `SIEMLoadTester` lub `MobileAppUser` |
| **Prometheus (Metryki)** | `http://serwer1pk:9090` | Podgląd targetów (`Status -> Targets`) i zapytań PromQL |
| **Alerty JSON** | `http://serwer1pk:8080/api/v1/alerts` | Bezpośredni podgląd najnowszych incydentów |

### Domyślne konta aplikacji mobilnej

* Administrator: `admin` / `admin123` (rola `admin`)
* Analityk: `analyst` / `analyst123` (rola `analyst`)

### Dodawanie nowego użytkownika do bazy MySQL

```bash
NEW_USER="nowy_analityk"
NEW_PASS="silnehaslo123"
NEW_ROLE="analyst"   # "analyst" lub "admin"

HASH=$(python3 -c "import hashlib, sys; print(hashlib.pbkdf2_hmac('sha256', sys.argv[1].encode(), b'mini-siem-static-salt-p2', 100_000).hex())" "$NEW_PASS")

docker compose exec -T db mysql -usiem -psiempass siemdb \
  -e "INSERT INTO users (username, password_hash, role) VALUES ('$NEW_USER', '$HASH', '$NEW_ROLE') ON DUPLICATE KEY UPDATE password_hash=VALUES(password_hash), role=VALUES(role);"
```

---

## 7. Uruchomienie, budowanie i CI/CD

### 7.1. Uruchomienie backendu (`mini-siem`)

1. *(Opcjonalnie — pod powiadomienia Push FCM)* Umieść plik klucza konta usługowego Firebase w `/home/user/siem-secrets/serviceAccountKey.json`. Bez tego pliku system również wystartuje poprawnie (wyłączy jedynie wysyłkę Push).
2. Uruchom wszystkie 10 kontenerów jednym poleceniem:
   ```bash
   docker compose up -d --build
   docker compose ps
   ```
3. Przydatne komendy operacyjne:
   ```bash
   docker compose logs -f analyzer                # Podgląd wykrywanych ataków i Push na żywo
   docker compose logs -f nginx                   # Podgląd ruchu HTTP/HTTPS
   docker compose exec -T redis redis-cli LLEN logs_queue   # Rozmiar kolejki w Redisie
   docker compose exec -T redis redis-cli DEL logs_queue    # Wyczyszczenie zaległej kolejki
   docker compose down                            # Zatrzymanie klastra (z zachowaniem danych MySQL)
   docker compose down -v                         # Pełny reset wraz z wyczyszczeniem bazy MySQL
   ```

### 7.2. Budowanie aplikacji mobilnej (`mini-siem-mobile`)

1. Wygeneruj plik `android/app/google-services.json` na podstawie szablonu `android/app/google-services.json.template`, podstawiając swój klucz `FIREBASE_API_KEY`.
2. Upewnij się, że w `lib/config.dart` wpisany jest poprawny adres serwera oraz odcisk SHA-256 certyfikatu z `nginx/certs/selfsigned.crt`.
3. Pobierz zależności, uruchom testy i zbuduj pakiet instalacyjny Androida:
   ```bash
   flutter pub get
   flutter analyze --no-fatal-infos
   flutter test
   flutter build apk --release
   ```
   Gotowy plik instalacyjny powstaje w `build/app/outputs/flutter-apk/app-release.apk`.

### 7.3. Automatyzacja CI/CD (GitHub Actions)

* **Backend (`mini-siem/.github/workflows/deploy.yml`):** Po każdym `git push` na gałąź `main` Self-Hosted Runner na `serwer1pk` pobiera kod, przebudowuje środowisko Docker Compose i uruchamia automatyczne testy.
* **Aplikacja mobilna (`mini-siem-mobile/.github/workflows/build-apk.yml`):** Po każdym `git push` na `main` chmurowy runner GitHub Actions odtwarza `google-services.json` z szablonu i sekretu **`FIREBASE_API_KEY`** (GitHub Secrets), uruchamia `flutter test`, kompiluje `app-release.apk` i udostępnia plik jako artefakt do pobrania w zakładce **Actions**.

---

## 8. Testy automatyczne, testy awarii i pomiary wydajności

### 8.1. Testy automatyczne backendu (7 testów `pytest`)

```bash
PYTHONPATH=. .venv/bin/pytest tests/test.py tests/test_integration.py tests/test_mobile_lww.py
```

* `tests/test.py` (4 testy jednostkowe): wykrywanie `SQL_INJECTION`, `PATH_TRAVERSAL`, `XSS_ATTACK` oraz brak fałszywych alarmów dla czystego ruchu.
* `tests/test_integration.py` (1 test E2E): pełny przepływ od `POST /api/v1/logs` przez Nginx, Collector, Redis i Analyzer aż do zapisu alertu w MySQL.
* `tests/test_mobile_lww.py` (2 testy integracyjne): logowanie JWT, zgłoszenie incydentu mobilnego, wygrana nowszej zmiany klienta i odrzucenie starszej zmiany (LWW) oraz filtrowanie przyrostowe `?since=` (Delta Sync).

### 8.2. Testy automatyczne aplikacji mobilnej (7 testów `flutter test` + test na urządzenie)

```bash
flutter test
```

* `test/lww_offline_test.dart` (6 testów jednostkowych): porównywanie znaczników UTC, rozwiązanie konfliktu offline w `SyncService`, logowanie offline SHA-256 (odrzucenie błędnego i przyjęcie poprawnego hasła) + ponowna weryfikacja JWT na serwerze oraz synchronizacja przyrostowa Delta Sync (`?since=`).
* `test/ui_flow_test.dart` (1 test widgetowy UI): pełna ścieżka użytkownika od ekranu logowania, przez wyświetlenie alertów, zakolejkowanie zgłoszenia w trybie offline, po synchronizację po powrocie sieci.
* `integration_test/app_test.dart`: test integracyjny na prawdziwym magazynie Hive i podpiętym urządzeniu Android (`flutter test integration_test/app_test.dart`).

### 8.3. Testy odporności na awarie

* **Awaria węzła backendu (na żywo):** Podczas działania generatora `.venv/bin/python generator/generate_traffic.py` zatrzymaj jedną replikę Collectora:
  ```bash
  docker stop collector-2
  # Ruch trafia bezbłędnie na collector-1 i collector-3; status widoczny w Grafanie
  docker start collector-2
  ```
* **Awaria sieci w aplikacji mobilnej i konflikt LWW:** Przełącz telefon w *Tryb samolotowy* (pasek zmienia się na czerwony `OFFLINE`), zmień status alertu (zapis do kolejki offline), wprowadź równoległą zmianę tego samego alertu po stronie serwera przez Swagger/API, a następnie przywróć sieć i obserwuj automatyczne rozstrzygnięcie konfliktu (baner LWW + wpis w oknie pomiarów).

