import requests
from typing import Dict, Any, List, Optional

class ACNClient:
    """Client Python officiel pour Priostack Agent Context Network (ACN)."""
    
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

    def connect(self, token: str, max_tokens: int = 512) -> Dict[str, Any]:
        """Connecte l'agent, initialise la session et retourne les identifiants/droits."""
        result = self._rpc_call("noetic.connect", {
            "token": token,
            "maxResponseTokens": max_tokens
        })
        # Stockage du sessionId
        if isinstance(result, dict) and "data" in result:
            self.session_id = result["data"].get("sessionId")
        else:
            self.session_id = result.get("sessionId")
        return result

    def create_space(
        self, 
        display_name: str, 
        default_rights: List[str] = ["read", "quote", "fact_use"]
    ) -> Dict[str, Any]:
        """Crée un espace de mémoire avec des droits par défaut (ceiling)."""
        if not self.session_id:
            raise ValueError("Appelez connect() avant de créer un espace.")
        return self._rpc_call("noetic.create_space", {
            "sessionId": self.session_id,
            "displayName": display_name,
            "defaultRights": default_rights
        })

    def store(self, space_id: str, objects: List[Dict[str, str]]) -> Dict[str, Any]:
        """Stocke des faits (observations ou déclarations) dans un espace."""
        if not self.session_id:
            raise ValueError("Appelez connect() avant de stocker du contexte.")
        return self._rpc_call("noetic.store", {
            "sessionId": self.session_id,
            "space": space_id,
            "objects": objects
        })

    def grant_access(
        self, 
        space_id: str, 
        subject_principal: str, 
        rights: List[str] = ["read", "quote"],
        world_mutation: str = "read"
    ) -> Dict[str, Any]:
        """
        Partage le contexte d'un espace avec un autre agent (Grant Initiation par le proprio).
        - rights: 'read', 'write', 'quote', 'share', 'export'
        - world_mutation: 'read', 'propose', 'mutate'
        """
        if not self.session_id:
            raise ValueError("Appelez connect() avant d'accorder des accès.")
        return self._rpc_call("noetic.grant", {
            "sessionId": self.session_id,
            "space": space_id,
            "subjectPrincipal": subject_principal,
            "rights": rights,
            "worldMutation": world_mutation
        })

    def request_access(self, space_id: str, requested_rights: List[str]) -> Dict[str, Any]:
        """Sollicite l'accès à un espace partagé distant (Consumer-initiated handshake)."""
        if not self.session_id:
            raise ValueError("Appelez connect() avant de demander un accès.")
        return self._rpc_call("noetic.request_access", {
            "sessionId": self.session_id,
            "space": space_id,
            "requestedRights": requested_rights
        })
