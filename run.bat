@echo off
call .venv\Scripts\activate.bat
python -m uvicorn api.main:app --reload
pause