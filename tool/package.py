#!/usr/bin/env python3
"""Package exactly the committed source, never local secrets or databases."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
out=root/'artifacts/Theater-App-Quellcode.zip'
out.parent.mkdir(exist_ok=True)
subprocess.run(['git','archive','--format=zip','--prefix=theater-app/','-o',str(out),'HEAD'],cwd=root,check=True)
print(out)
