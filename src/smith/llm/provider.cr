module Smith::LLM
  class ResponseError < Exception
    getter status_code : Int32

    def initialize(@status_code : Int32, message : String)
      super(message)
    end
  end

  abstract class Provider
    abstract def name : String
    abstract def default_model : String
    abstract def complete(request : Request) : Response
  end
end
