class StoreResponse:
    def __init__(self, store_response, node):
        self.response = store_response
        self.node = node

    @property
    def request_id(self):
        try:
            if self.node.is_nwaku():
                return self.response.get("requestId")
            else:
                return self.response.get("request_id")
        except:
            return None

    @property
    def status_code(self):
        try:
            if self.node.is_nwaku():
                return self.response.get("statusCode")
            else:
                return self.response.get("status_code")
        except:
            return None

    @property
    def status_desc(self):
        try:
            if self.node.is_nwaku():
                return self.response.get("statusDesc")
            else:
                return self.response.get("status_desc")
        except:
            return None

    @property
    def messages(self):
        try:
            return self.response.get("messages")
        except:
            return None

    @property
    def pagination_cursor(self):
        try:
            if self.node.is_nwaku():
                return self.response.get("paginationCursor")
            else:
                return self.response.get("pagination_cursor")
        except:
            return None

    def message_hash(self, index):
        if self.messages is not None:
            if self.node.is_nwaku():
                return self.messages[index]["messageHash"]
            else:
                return self.messages[index]["message_hash"]
        else:
            return None

    @property
    def resp_json(self):
        return self.response
