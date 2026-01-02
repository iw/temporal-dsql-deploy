FROM golang:1.23-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git ca-certificates

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY main.go ./

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o dsql-test main.go

# Final stage
FROM alpine:3.22

# Install runtime dependencies
RUN apk add --no-cache ca-certificates aws-cli

# Create non-root user
RUN addgroup -g 1000 dsqltest && \
    adduser -D -s /bin/sh -u 1000 -G dsqltest dsqltest

WORKDIR /app

# Copy the binary from builder stage
COPY --from=builder /app/dsql-test .

# Change ownership
RUN chown dsqltest:dsqltest /app/dsql-test

USER dsqltest

ENTRYPOINT ["./dsql-test"]