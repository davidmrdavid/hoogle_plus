import _ from "underscore";
import {v4} from "uuid";
import { usageToId } from "../utilities/args";
import {baseRoute} from "../constants/strings";

export const typeSearch = ({query, examples}, cb) => {
    const ROUTE = baseRoute + "search/type";

    let data = {
        typeSignature: query,
        facts: examples || []
    };

    const mockCandidate = {
        candidate: "\\arg0 arg1-> catMaybes (listToMaybe arg0) arg1",
        examples: [
            ["z", "2", "zz"],
            ["z", "5", "zzzzz"],
            ["abc", "-1", "error"],
        ]
    };
    const mockResponse = {
        id: v4(),
        results: [mockCandidate],
    }

    const convertToState = ({id, candidate, examples}) => {
        const newResults = {
                candidateId: v4(),
                code: candidate,
                examplesLoading: false,
                examples: examples.map(usage => {
                    return {
                        id: usageToId(usage),
                        usage: usage,
                        isLoading: false,
                    };}),
            };
        return {
            queryId: id,
            result: newResults
        };
    };

    const fetchOpts = {
        method: 'POST', // or 'PUT'
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(data),
    };
    return streamResponse(ROUTE, fetchOpts, (jsonBlob => {
        console.log("onIncrementalResponse", jsonBlob);
        const newState = convertToState(jsonBlob);
        cb(newState);
    }));
}

// Returns a promise of the whole accumulated response, as text
// onIncrementalResponse is called on each chunk received.
const streamResponse = (route, fetchOpts, onIncrementalResponse) => {
    const decoder = new TextDecoder("utf-8")

    return fetch(route, fetchOpts)
        .then(response => response.body)
        .then(body => {
            const reader = body.getReader();
            return new ReadableStream({
                start(controller) {
                return pump();
                function pump() {
                    return reader.read().then(({ done, value }) => {
                    // When no more data needs to be consumed, close the stream
                    if (done) {
                        controller.close();
                        return;
                    }
                    // Enqueue the next data chunk into our target stream
                    const convertedValue = decoder.decode(value);
                    console.log("convertedValue", convertedValue);
                    convertedValue.trim().split("\n").map(jsonStr => {
                        try {
                            const jsonBlob = JSON.parse(jsonStr);
                            onIncrementalResponse(jsonBlob);
                            console.log("convertedValue sent:", jsonBlob);
                        } catch (error) {
                            console.error("convertedValue", error);
                        }
                    })
                    controller.enqueue(value);
                    return pump();
                    });
                }
                }
            });
        })
        .then(stream => new Response(stream))
}

export default {
    typeSearch,
};