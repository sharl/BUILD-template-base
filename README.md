# __name__



## Run

```powershell
git clone https://github.com/sharl/__name__.git
cd __name__
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
python __name__.py
```

```bash
git clone https://github.com/sharl/__name__.git
cd __name__
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python __name__.py
```

### Re-run

```powershell
cd __name__
.\.venv\Scripts\activate
python __name__.py
```

```bash
cd __name__
source .venv/bin/activate
python __name__.py
```

## Build

```powershell
pip install pyinstaller
__pyinstaller__cmd__
```
