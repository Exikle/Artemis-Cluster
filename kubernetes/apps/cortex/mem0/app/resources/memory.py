"""
Memory client utilities for OpenMemory.

Patched for Artemis-Cluster: uses env vars for Qdrant host/key and Ollama base URL
instead of Docker Compose defaults.
"""

import os
import json
import hashlib
import socket
import platform

from mem0 import Memory
from app.database import SessionLocal
from app.models import Config as ConfigModel


_memory_client = None
_config_hash = None


def _get_config_hash(config_dict):
    """Generate a hash of the config to detect changes."""
    config_str = json.dumps(config_dict, sort_keys=True)
    return hashlib.md5(config_str.encode()).hexdigest()


def _get_docker_host_url():
    custom_host = os.environ.get('OLLAMA_HOST')
    if custom_host:
        return custom_host.replace('http://', '').replace('https://', '').split(':')[0]
    if not os.path.exists('/.dockerenv'):
        return "localhost"
    host_candidates = []
    try:
        socket.gethostbyname('host.docker.internal')
        host_candidates.append('host.docker.internal')
    except socket.gaierror:
        pass
    try:
        with open('/proc/net/route', 'r') as f:
            for line in f:
                fields = line.strip().split()
                if fields[1] == '00000000':
                    gateway_hex = fields[2]
                    gateway_ip = socket.inet_ntoa(bytes.fromhex(gateway_hex)[::-1])
                    host_candidates.append(gateway_ip)
                    break
    except (FileNotFoundError, IndexError, ValueError):
        pass
    return host_candidates[0] if host_candidates else '172.17.0.1'


def _fix_ollama_urls(config_section):
    if not config_section or "config" not in config_section:
        return config_section
    ollama_config = config_section["config"]
    if "ollama_base_url" not in ollama_config:
        ollama_config["ollama_base_url"] = "http://host.docker.internal:11434"
    else:
        url = ollama_config["ollama_base_url"]
        if "localhost" in url or "127.0.0.1" in url:
            docker_host = _get_docker_host_url()
            if docker_host != "localhost":
                new_url = url.replace("localhost", docker_host).replace("127.0.0.1", docker_host)
                ollama_config["ollama_base_url"] = new_url
    return config_section


def reset_memory_client():
    """Reset the global memory client to force reinitialization with new config."""
    global _memory_client, _config_hash
    _memory_client = None
    _config_hash = None


def get_default_memory_config():
    """Get default memory client configuration — reads cluster env vars for Qdrant and Ollama."""
    return {
        "vector_store": {
            "provider": "qdrant",
            "config": {
                "collection_name": "openmemory",
                "url": "env:QDRANT_URL",
                "api_key": "env:QDRANT_API_KEY",
            }
        },
        "llm": {
            "provider": "openai",
            "config": {
                "model": "qwen2.5:3b",
                "temperature": 0.1,
                "max_tokens": 2000,
                "api_key": "env:OPENAI_API_KEY",
                "openai_base_url": "env:OLLAMA_BASE_URL"
            }
        },
        "embedder": {
            "provider": "openai",
            "config": {
                "model": "nomic-embed-text",
                "api_key": "env:OPENAI_API_KEY",
                "openai_base_url": "env:OLLAMA_BASE_URL"
            }
        },
        "version": "v1.1"
    }


def _parse_environment_variables(config_dict):
    """Converts 'env:VARIABLE_NAME' strings to actual environment variable values."""
    if isinstance(config_dict, dict):
        parsed_config = {}
        for key, value in config_dict.items():
            if isinstance(value, str) and value.startswith("env:"):
                env_var = value.split(":", 1)[1]
                env_value = os.environ.get(env_var)
                if env_value:
                    parsed_config[key] = env_value
                    print(f"Loaded {env_var} from environment for {key}")
                else:
                    print(f"Warning: Environment variable {env_var} not found, keeping original value")
                    parsed_config[key] = value
            elif isinstance(value, dict):
                parsed_config[key] = _parse_environment_variables(value)
            else:
                parsed_config[key] = value
        return parsed_config
    return config_dict


def get_memory_client(custom_instructions: str = None):
    """Get or initialize the Mem0 client."""
    global _memory_client, _config_hash

    try:
        config = get_default_memory_config()
        db_custom_instructions = None

        try:
            db = SessionLocal()
            db_config = db.query(ConfigModel).filter(ConfigModel.key == "main").first()

            if db_config:
                json_config = db_config.value

                if "openmemory" in json_config and "custom_instructions" in json_config["openmemory"]:
                    db_custom_instructions = json_config["openmemory"]["custom_instructions"]

                if "mem0" in json_config:
                    mem0_config = json_config["mem0"]

                    if "llm" in mem0_config and mem0_config["llm"] is not None:
                        config["llm"] = mem0_config["llm"]
                        if config["llm"].get("provider") == "ollama":
                            config["llm"] = _fix_ollama_urls(config["llm"])

                    if "embedder" in mem0_config and mem0_config["embedder"] is not None:
                        config["embedder"] = mem0_config["embedder"]
                        if config["embedder"].get("provider") == "ollama":
                            config["embedder"] = _fix_ollama_urls(config["embedder"])

                    if "vector_store" in mem0_config and mem0_config["vector_store"] is not None:
                        config["vector_store"] = mem0_config["vector_store"]
            else:
                print("No configuration found in database, using defaults")

            db.close()

        except Exception as e:
            print(f"Warning: Error loading configuration from database: {e}")
            print("Using default configuration")

        instructions_to_use = custom_instructions or db_custom_instructions
        if instructions_to_use:
            config["custom_fact_extraction_prompt"] = instructions_to_use

        print("Parsing environment variables in final config...")
        config = _parse_environment_variables(config)

        current_config_hash = _get_config_hash(config)

        if _memory_client is None or _config_hash != current_config_hash:
            print(f"Initializing memory client with config hash: {current_config_hash}")
            try:
                _memory_client = Memory.from_config(config_dict=config)
                _config_hash = current_config_hash
                print("Memory client initialized successfully")
            except Exception as init_error:
                print(f"Warning: Failed to initialize memory client: {init_error}")
                print("Server will continue running with limited memory functionality")
                _memory_client = None
                _config_hash = None
                return None

        return _memory_client

    except Exception as e:
        print(f"Warning: Exception occurred while initializing memory client: {e}")
        print("Server will continue running with limited memory functionality")
        return None


def get_default_user_id():
    return "default_user"
