import requests
from typing import Dict, Any, List, Optional

class ACNClient:
    """Client Python léger pour Priostack Agent Context Network (ACN)."""
    
    def __init__(self, endpoint: str = "https://priostack.com/acn/rpc"):
        self.endpoint = endpoint
        self.session_id: Optional[str] = None

    def _rpc_call(self, method_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": method_name,
                "arguments": arguments
            }
        }
        response = requests.post(self.endpoint, json=payload)
        response.raise_for_status()
        res_data = response.json()
        if "error" in res_data:
            raise Exception(f"ACN Error: {res_data['error']}")
        return res_data.get("result", {})

    def register(self, display_name: str) -> str:
        """Enregistre l'agent de manière autonome et retourne la clé ACN."""
        result = self._rpc_call("noetic.register", {"displayName": display_name})
        return result.get("token") or result.get("content", [{}])[0].get("text")

    def connect(self, token: str, max_tokens: int = 4096) -> str:
        """Connecte l'agent et obtient un sessionId pour les opérations de mémoire."""
        result = self._rpc_call("noetic.connect", {
            "token": token,
            "maxResponseTokens": max_tokens
        })
        self.session_id = result.get("sessionId")
        return self.session_id

    def create_space(self, display_name: str) -> str:
        """Crée un espace de mémoire étanche."""
        if not self.session_id:
            raise ValueError("Vous devez appeler connect() avant de créer un espace.")
        return self._rpc_call("noetic.create_space", {
            "sessionId": self.session_id,
            "displayName": display_name
        })

    def store(self, space_id: str, content: str, object_type: str = "declaration") -> Dict[str, Any]:
        """Stocke une mémoire (observation ou déclaration) dans un espace."""
        if not self.session_id:
            raise ValueError("Vous devez appeler connect() avant de stocker du contexte.")
        return self._rpc_call("noetic.store", {
            "sessionId": self.session_id,
            "space": space_id,
            "objects": [{"content": content, "type": object_type}]
        })
