#!/bin/bash
set -e
echo "[Harbor Oracle] Applying ground-truth fix patch to midiconnect.py..."

cat << 'EOF' > /workspace/midiconnect.py
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

# You will need to change this to the port the specific Roblox game uses!
# (e.g., 8080, 64286, etc. Check the game's official MIDI app to find out).
PORT = 8080 

class FakeMidiBridge(BaseHTTPRequestHandler):
    # This disables the terminal spam so it runs quietly
    def log_message(self, format, *args):
        pass

    # Roblox will send a GET request to your local IP
    def do_GET(self):
        # 1. Send a "200 OK" status (telling Roblox the server exists)
        self.send_response(200)
        
        # 2. Tell Roblox we are sending JSON data back
        self.send_header('Content-type', 'application/json')
        # Crucial: Allow Roblox to read it (CORS policy)
        self.send_header('Access-Control-Allow-Origin', '*') 
        self.end_headers()

        # 3. THE FAKE PAYLOAD
        # This is where you trick the game. You must match the format 
        # the specific Roblox game expects. 
        fake_status = {
            "connected": True,
            "device_name": "Yamaha Grand Piano Pro", # Flex a fake expensive piano!
            "notes": [] 
        }
        
        # Send the fake data to Roblox
        self.wfile.write(json.dumps(fake_status).encode('utf-8'))

# Start the fake server
if __name__ == '__main__':
    server = HTTPServer(('localhost', PORT), FakeMidiBridge)
    print(f"Fake MIDI Bridge running on port {PORT}...")
    print("Go into the Roblox game and hit 'Connect MIDI'!")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down prank.")
        server.server_close()
EOF

echo "[Harbor Oracle] Patch applied successfully."
