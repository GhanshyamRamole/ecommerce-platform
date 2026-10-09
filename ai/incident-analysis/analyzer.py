"""
AI Incident Analysis Service
Analyzes logs from Elasticsearch/Loki and provides incident insights using LLM.
Supports multiple LLM providers: Groq (free), OpenAI, with mock fallback.
"""
import os
import json
import logging
from datetime import datetime, timezone
from typing import Dict, List
from dataclasses import dataclass, asdict

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Try to import optional dependencies
try:
    from opensearchpy import OpenSearch
    OPENSEARCH_AVAILABLE = True
except ImportError:
    OPENSEARCH_AVAILABLE = False
    logger.warning("opensearchpy not available, using mock client")

try:
    import openai  # noqa: F401
    OPENAI_AVAILABLE = True
except ImportError:
    OPENAI_AVAILABLE = False
    logger.warning("openai not available")

try:
    from groq import Groq
    GROQ_AVAILABLE = True
except ImportError:
    GROQ_AVAILABLE = False
    logger.warning("groq not available")


@dataclass
class IncidentReport:
    """Structured incident analysis output"""
    error_classification: str
    severity: str  # critical, high, medium, low
    possible_root_cause: str
    suggested_investigation: List[str]
    suggested_remediation: List[str]
    timestamp: str
    log_samples: List[str]
    confidence: float


class LogCollector:
    """Collects error logs from various sources"""
    
    def __init__(self, config: Dict):
        self.config = config
        self.opensearch_client = None
        if OPENSEARCH_AVAILABLE and config.get('opensearch'):
            opensearch_config = config['opensearch']
            # Handle string "true"/"false" from environment variables
            use_ssl = opensearch_config.get('use_ssl', True)
            if isinstance(use_ssl, str):
                use_ssl = use_ssl.lower() == 'true'
            
            verify_certs = opensearch_config.get('verify_certs', True)
            if isinstance(verify_certs, str):
                verify_certs = verify_certs.lower() == 'true'
            
            self.opensearch_client = OpenSearch(
                hosts=[{
                    'host': opensearch_config['host'],
                    'port': opensearch_config.get('port', 9200)
                }],
                http_auth=(opensearch_config['user'], opensearch_config['password']),
                use_ssl=use_ssl,
                verify_certs=verify_certs,
            )
    
    def collect_errors(self, since_minutes: int = 30, limit: int = 100) -> List[Dict]:
        """Collect error logs from the last N minutes"""
        if self.opensearch_client:
            return self._collect_from_opensearch(since_minutes, limit)
        else:
            return self._collect_mock(since_minutes, limit)
    
    def _collect_from_opensearch(self, since_minutes: int, limit: int) -> List[Dict]:
        """Collect from OpenSearch/Elasticsearch"""
        query = {
            "size": limit,
            "query": {
                "bool": {
                    "must": [
                        {"range": {"@timestamp": {"gte": f"now-{since_minutes}m"}}},
                        {"terms": {"level": ["ERROR", "CRITICAL", "FATAL"]}}
                    ]
                }
            },
            "sort": [{"@timestamp": {"order": "desc"}}]
        }
        
        try:
            response = self.opensearch_client.search(
                index=self.config['opensearch'].get('index', 'logs-*'),
                body=query
            )
            return [hit['_source'] for hit in response['hits']['hits']]
        except Exception as e:
            logger.error(f"OpenSearch query failed: {e}")
            return []
    
    def _collect_mock(self, since_minutes: int, limit: int) -> List[Dict]:
        """Mock data for testing"""
        now = datetime.now(timezone.utc).isoformat()
        return [
            {
                "@timestamp": now,
                "level": "ERROR",
                "message": "Connection refused to database: postgres:5432",
                "service": "backend",
                "trace_id": "abc123",
                "stack_trace": "asyncpg.exceptions.ConnectionDoesNotExistError: connection does not exist"
            },
            {
                "@timestamp": now,
                "level": "ERROR",
                "message": "Timeout connecting to database",
                "service": "backend",
                "trace_id": "def456",
                "stack_trace": "asyncio.TimeoutError: timeout after 30s"
            }
        ]


class LLMAnalyzer:
    """Analyzes logs using LLM with fallback chain: Groq -> OpenAI -> Mock"""
    
    def __init__(self, config: Dict):
        self.config = config
        self.groq_client = None
        self.openai_client = None
        
        # Priority 1: Groq (free, generous limits)
        if GROQ_AVAILABLE and config.get('groq', {}).get('api_key'):
            self.groq_client = Groq(api_key=config['groq']['api_key'])
            logger.info("LLM Provider: Groq (primary)")
        
        # Priority 2: OpenAI (fallback)
        elif OPENAI_AVAILABLE and config.get('openai', {}).get('api_key'):
            import openai
            openai.api_key = config['openai']['api_key']
            self.openai_client = openai
            logger.info("LLM Provider: OpenAI (fallback)")
        
        # Priority 3: Mock (final fallback)
        else:
            logger.warning("No LLM provider available, using mock analysis")
    
    def analyze(self, logs: List[Dict]) -> IncidentReport:
        """Analyze logs and generate incident report"""
        if not logs:
            return IncidentReport(
                error_classification="none",
                severity="low",
                possible_root_cause="No errors detected",
                suggested_investigation=[],
                suggested_remediation=[],
                timestamp=datetime.now(timezone.utc).isoformat(),
                log_samples=[],
                confidence=1.0
            )
        
        # Prepare log context for LLM
        self._prepare_context(logs)
        
        # Try providers in order: Groq -> OpenAI -> Mock
        if self.groq_client:
            return self._analyze_with_groq(logs)
        elif self.openai_client:
            return self._analyze_with_openai(logs)
        else:
            return self._analyze_mock(logs)
    
    def _prepare_context(self, logs: List[Dict]) -> str:
        """Prepare log context for LLM prompt"""
        context = "Analyze these application error logs and provide incident analysis:\n\n"
        for log in logs[:10]:  # Limit to 10 logs
            context += f"Time: {log.get('@timestamp', 'N/A')}\n"
            context += f"Level: {log.get('level', 'N/A')}\n"
            context += f"Service: {log.get('service', 'N/A')}\n"
            context += f"Message: {log.get('message', 'N/A')}\n"
            if log.get('stack_trace'):
                context += f"Stack: {log['stack_trace'][:500]}\n"
            context += "---\n"
        return context
    
    def _build_prompt(self, context: str) -> str:
        """Build the analysis prompt"""
        return f"""{context}

Provide a JSON response with ALL of these required fields (MUST include all):
1. error_classification: Category (database, network, auth, timeout, resource, config, unknown)
2. severity: critical/high/medium/low
3. possible_root_cause: Brief explanation (string)
4. suggested_investigation: Array of strings (investigation steps)
5. suggested_remediation: Array of strings (remediation steps) - REQUIRED
6. confidence: Number between 0.0 and 1.0 - REQUIRED

Example format:
{{
  "error_classification": "database",
  "severity": "critical",
  "possible_root_cause": "PostgreSQL connection pool exhausted",
  "suggested_investigation": ["Check PostgreSQL status", "Verify pool settings"],
  "suggested_remediation": ["Increase pool size", "Add retry logic"],
  "confidence": 0.9
}}

Only output valid JSON with all fields."""

    def _parse_llm_response(self, response_content: str, logs: List[Dict]) -> IncidentReport:
        """Parse LLM response into IncidentReport with defaults for missing fields"""
        try:
            result = json.loads(response_content)
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse LLM response as JSON: {e}")
            return self._analyze_mock(logs)
        
        if not isinstance(result, dict):
            logger.error(f"LLM response is not a JSON object: {type(result)}")
            return self._analyze_mock(logs)
        
        result['timestamp'] = datetime.now(timezone.utc).isoformat()
        result['log_samples'] = [log.get('message', '') for log in logs[:5]]
        
        # Ensure all required fields exist with defaults
        if 'suggested_remediation' not in result:
            result['suggested_remediation'] = [
                "Add more specific error handling",
                "Improve logging context"
            ]
        if 'confidence' not in result:
            result['confidence'] = 0.5
        if 'suggested_investigation' not in result:
            result['suggested_investigation'] = [
                "Review full stack traces",
                "Correlate with deployment timeline",
                "Check recent configuration changes"
            ]
        
        return IncidentReport(**result)

    def _analyze_with_groq(self, logs: List[Dict]) -> IncidentReport:
        """Use Groq to analyze logs"""
        context = self._prepare_context(logs)
        prompt = self._build_prompt(context)
        model = self.config.get('groq', {}).get('model', 'llama-3.1-8b-instant')
        
        try:
            logger.info(f"Analyzing with Groq model: {model}")
            response = self.groq_client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": "You are an expert DevOps/SRE incident analyzer. Provide concise, actionable analysis."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.1,
                max_tokens=2000,
            )
            
            result = self._parse_llm_response(response.choices[0].message.content, logs)
            return result
        except Exception as e:
            logger.error(f"Groq analysis failed: {e}")
            return self._analyze_with_openai(logs) if self.openai_client else self._analyze_mock(logs)
    
    def _analyze_with_openai(self, logs: List[Dict]) -> IncidentReport:
        """Use OpenAI to analyze logs (fallback)"""
        context = self._prepare_context(logs)
        prompt = self._build_prompt(context)
        model = self.config.get('openai', {}).get('model', 'gpt-4o-mini')
        
        try:
            logger.info(f"Analyzing with OpenAI model: {model}")
            import openai
            response = openai.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": "You are an expert DevOps/SRE incident analyzer. Provide concise, actionable analysis."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.1,
                max_tokens=1000,
                response_format={"type": "json_object"}
            )
            
            result = self._parse_llm_response(response.choices[0].message.content, logs)
            return result
        except Exception as e:
            logger.error(f"OpenAI analysis failed: {e}")
            return self._analyze_mock(logs)
    
    def _analyze_mock(self, logs: List[Dict]) -> IncidentReport:
        """Mock analysis for testing"""
        # Simple pattern matching for common issues
        messages = [log.get('message', '').lower() for log in logs]
        combined = ' '.join(messages)
        
        now = datetime.now(timezone.utc).isoformat()
        
        if 'connection refused' in combined or 'connection does not exist' in combined:
            return IncidentReport(
                error_classification="database",
                severity="critical",
                possible_root_cause="PostgreSQL connection pool exhausted or database unavailable",
                suggested_investigation=[
                    "Check PostgreSQL process status",
                    "Verify connection pool settings (pool_size, max_overflow)",
                    "Check network connectivity to database",
                    "Review database connection limits"
                ],
                suggested_remediation=[
                    "Increase connection pool size",
                    "Add connection retry logic with exponential backoff",
                    "Scale database vertically or add read replicas",
                    "Implement circuit breaker pattern"
                ],
                timestamp=now,
                log_samples=[log.get('message', '') for log in logs[:5]],
                confidence=0.9
            )
        elif 'timeout' in combined:
            return IncidentReport(
                error_classification="timeout",
                severity="high",
                possible_root_cause="Database query timeout or slow queries",
                suggested_investigation=[
                    "Check slow query logs",
                    "Review query execution plans",
                    "Check database load and resource usage"
                ],
                suggested_remediation=[
                    "Optimize slow queries with indexes",
                    "Increase query timeout settings",
                    "Implement query caching"
                ],
                timestamp=now,
                log_samples=[log.get('message', '') for log in logs[:5]],
                confidence=0.8
            )
        else:
            return IncidentReport(
                error_classification="unknown",
                severity="medium",
                possible_root_cause="Unclassified error pattern",
                suggested_investigation=[
                    "Review full stack traces",
                    "Correlate with deployment timeline",
                    "Check recent configuration changes"
                ],
                suggested_remediation=[
                    "Add more specific error handling",
                    "Improve logging context"
                ],
                timestamp=now,
                log_samples=[log.get('message', '') for log in logs[:5]],
                confidence=0.3
            )


class IncidentAnalyzer:
    """Main incident analysis orchestrator"""
    
    def __init__(self, config: Dict):
        self.config = config
        self.collector = LogCollector(config)
        self.analyzer = LLMAnalyzer(config)
    
    def analyze_recent(self, since_minutes: int = 30) -> IncidentReport:
        """Analyze recent incidents"""
        logger.info(f"Collecting logs from last {since_minutes} minutes...")
        logs = self.collector.collect_errors(since_minutes=since_minutes)
        logger.info(f"Collected {len(logs)} error logs")
        
        logger.info("Analyzing with LLM...")
        report = self.analyzer.analyze(logs)
        
        logger.info(f"Analysis complete: {report.error_classification} ({report.severity})")
        return report
    
    def run_continuous(self, interval_minutes: int = 15, alert_webhook: str = None):
        """Run continuous monitoring"""
        import time
        logger.info(f"Starting continuous monitoring (interval: {interval_minutes}min)")
        
        while True:
            try:
                report = self.analyze_recent(since_minutes=interval_minutes)
                
                if report.severity in ['critical', 'high'] and alert_webhook:
                    self._send_alert(report, alert_webhook)
                
                time.sleep(interval_minutes * 60)
            except KeyboardInterrupt:
                logger.info("Monitoring stopped")
                break
            except Exception as e:
                logger.error(f"Monitoring error: {e}")
                time.sleep(60)
    
    def _send_alert(self, report: IncidentReport, webhook: str):
        """Send alert to webhook (Slack, Teams, etc.)"""
        import requests
        payload = {
            "text": f"🚨 Incident Alert: {report.error_classification} ({report.severity})",
            "blocks": [
                {"type": "section", "text": {"type": "mrkdwn", "text": "*Incident Analysis*"}},
                {"type": "section", "fields": [
                    {"type": "mrkdwn", "text": f"*Classification:*\n{report.error_classification}"},
                    {"type": "mrkdwn", "text": f"*Severity:*\n{report.severity}"}
                ]},
                {"type": "section", "text": {"type": "mrkdwn", "text": f"*Root Cause:*\n{report.possible_root_cause}"}},
                {"type": "section", "text": {"type": "mrkdwn", "text": "*Investigation:*\n" + "\n".join(f"• {s}" for s in report.suggested_investigation)}},
                {"type": "section", "text": {"type": "mrkdwn", "text": "*Remediation:*\n" + "\n".join(f"• {s}" for s in report.suggested_remediation)}}
            ]
        }
        try:
            requests.post(webhook, json=payload, timeout=10)
        except Exception as e:
            logger.error(f"Alert failed: {e}")


def main():
    """Main entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description="AI Incident Analyzer")
    parser.add_argument('--once', action='store_true', help='Run single analysis')
    parser.add_argument('--interval', type=int, default=15, help='Monitoring interval (minutes)')
    parser.add_argument('--webhook', help='Alert webhook URL')
    parser.add_argument('--since', type=int, default=30, help='Look back window (minutes)')
    
    args = parser.parse_args()
    
    config = {
        'opensearch': {
            'host': os.getenv('OPENSEARCH_HOST', 'localhost'),
            'port': int(os.getenv('OPENSEARCH_PORT', 9200)),
            'user': os.getenv('OPENSEARCH_USER', 'admin'),
            'password': os.getenv('OPENSEARCH_PASSWORD', 'admin'),
            'use_ssl': os.getenv('OPENSEARCH_SSL', 'true').lower() == 'true',
            'verify_certs': os.getenv('OPENSEARCH_VERIFY', 'false').lower() == 'true',
            'index': os.getenv('OPENSEARCH_INDEX', 'logs-*')
        },
        'groq': {
            'api_key': os.getenv('GROQ_API_KEY'),
            'model': os.getenv('GROQ_MODEL', 'llama-3.1-8b-instant')
        },
        'openai': {
            'api_key': os.getenv('OPENAI_API_KEY'),
            'model': os.getenv('OPENAI_MODEL', 'gpt-4o-mini')
        }
    }
    
    analyzer = IncidentAnalyzer(config)
    
    if args.once:
        report = analyzer.analyze_recent(args.since)
        print(json.dumps(asdict(report), indent=2))
    else:
        analyzer.run_continuous(args.interval, args.webhook)


if __name__ == '__main__':
    main()