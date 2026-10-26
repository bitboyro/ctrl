import unittest
from app.server import greeting


class GreetingTests(unittest.TestCase):
    def test_named_greeting(self):
        self.assertEqual(greeting('Ada'), 'Hello, Ada!')

    def test_input_is_text_not_code(self):
        self.assertEqual(greeting('$(echo hello)'), 'Hello, $(echo hello)!')
