#!/usr/bin/python3

import flask
import os
import sys
from Crypto.PublicKey import RSA
from Crypto.Signature import pkcs1_15
from Crypto.Hash import SHA256, HMAC
from Crypto.Cipher import AES, PKCS1_OAEP
from Crypto.Random import get_random_bytes
from Crypto.Util.Padding import pad
import logging
import json
import base64


log = logging.getLogger(__name__)
log.setLevel(getattr(logging, os.getenv('LOGLEVEL', 'INFO').upper(), 'INFO'))
handler = logging.StreamHandler(sys.stderr)
formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(name)s %(message)s')
handler.setFormatter(formatter)
log.addHandler(handler)

app = flask.Flask(__name__)
app.config['DEBUG'] = os.getenv('LOGLEVEL', 'INFO').upper() == 'DEBUG'

@app.route('/', methods=['GET'])
def get_root():
  flask.abort(405)

@app.route('/images/<path:image_path>')
def send_report(image_path):
  if not app.config['enable_images']:
    flask.abort(500)
  if not os.path.exists(os.path.join(app.config['root'], 'images', image_path)):
    flask.abort(404)
  return flask.send_file(os.path.join(app.config['root'], 'images', image_path))

@app.route('/registry/health', methods=['GET'])
def get_health():
  return ''

@app.route('/registry/node-configs/<path:node_mac_filename>', methods=['GET'])
def get_node_config(node_mac_filename):
  node_config_path = os.path.join(app.config['root'], 'node-configs', node_mac_filename)
  if not os.path.exists(node_config_path):
    flask.abort(404)
  node_state_path = os.path.join(app.config['root'], 'node-states', node_mac_filename)
  if not os.path.exists(node_state_path):
    flask.abort(500)

  with open(node_state_path, 'r') as h:
    node_key = RSA.import_key(json.loads(h.read())['node-key']['public'])

  with open(node_config_path, 'r') as h:
    try:
      raw_json = h.read()
      json.loads(raw_json)  # Make sure we are sending back valid JSON
    except Exception as e:
      log.error(e)
      flask.abort(500)

  aes_key = get_random_bytes(32)
  aes_iv = get_random_bytes(16)
  hmac_key = get_random_bytes(16)

  enc = AES.new(aes_key, AES.MODE_CBC, iv=aes_iv)
  encrypted_config = enc.encrypt(pad(raw_json.encode('ascii'), AES.block_size))

  encrypted_cipher = PKCS1_OAEP.new(node_key).encrypt(aes_key + aes_iv + hmac_key)

  return {
    'result': 'OK',
    'encrypted-chipher': base64.b64encode(encrypted_cipher).decode('ascii'),
    'encrypted-config-hmac': base64.b64encode(HMAC.new(key=hmac_key, msg=encrypted_config, digestmod=SHA256).digest()).decode('ascii'),
    'encrypted-config': base64.b64encode(encrypted_config).decode('ascii'),
  }

@app.route('/registry/node-states/<path:node_mac_filename>', methods=['PUT'])
def put_node_state(node_mac_filename):
  node_state_path = os.path.join(app.config['root'], 'node-states', node_mac_filename)
  node_key_pem = None
  if os.path.exists(node_state_path):
    # If the node has informed us that the node-key has been persisted
    # enforce the signature on the new node-state
    with open(node_state_path, 'r') as h:
      previous_state = json.loads(h.read())
      if previous_state['node-key']['persisted']:
        node_key_pem = previous_state['node-key']['public']

  try:
    node_state = json.loads(flask.request.get_data())
    sig = node_state['signature']
    del node_state['signature']
    to_sign = SHA256.new(json.dumps(node_state, sort_keys=True, separators=(',', ':')).encode('ascii'))
    if node_key_pem is None:
      # There is no previous node-state or the node-key
      # has not been persisted yet.
      # Trust the submitted node-key
      node_key_pem = node_state['node-key']['public']
    node_key = RSA.import_key(node_key_pem)
  except Exception as e:
    log.error(e)
    flask.abort(400)
  try:
    pkcs1_15.new(node_key).verify(to_sign, base64.b64decode(sig))
  except Exception as e:
    flask.abort(403)

  with open(node_state_path, 'w') as h:
    try:
      h.write(json.dumps(node_state, indent=2))
    except Exception as e:
      log.error(e)
      flask.abort(500)

  return {'result': 'OK'}

def gunicorn(root, enable_images=False):
  app.config['root'] = root
  app.config['enable_images'] = enable_images
  return app

if __name__ == '__main__':
  app.config['root'] = sys.argv[1]
  app.run()
